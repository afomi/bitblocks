defmodule Bitblocks.Derivations do
  @moduledoc """
  Provenance for derived data (`docs/DERIVED_DATA.md`): the record of every
  backfill run, and the runner the backfills share.

  `run/2` takes a backfill's batch function and does the rest the same way
  for every derivation:

    * writes a `derivation_runs` row before the first batch (`running`) and
      finishes it with the counts and the outcome, dry runs included;
    * calls the batch function until it says `:done`, keeping the report
      after each batch, so an error records `partial` (with the error) and
      leaves the batches before it applied;
    * prints progress through `:on_batch`;
    * after each batch, asks `:after_batch` (given the cursor the next batch
      starts after, and the report) whether to go on (`:cont`) or stop
      there (`:halt`), which records `halted`: a clean stop at a batch
      boundary, for `Bitblocks.BackfillChains` to hand the rest on.

  The batch function bounds its own statements with `bounded/2` (a short
  transaction under a `statement_timeout`) and calls `pause/1` after each
  write, so autovacuum keeps up with the non-HOT updates on `transactions`.

  ## A batch's wall time (https://github.com/afomi/bitblocks/issues/115)

  A batch is the unit a chain checkpoints and hands off at, so its length is
  how long a deploy waits for it. `run/2` keeps each one near `:batch_ms`
  (default `config :bitblocks, :derivation_batch_ms`, 20,000) two ways:

    * **A deadline.** Before each batch it sets one, and the batch function
      asks `time_up?/0` between blocks and between the committed pages of a
      block; once it is true (or `:interrupt?` is: the node is stopping),
      the batch ends there and returns its cursor. A block backfill walks
      its blocks with `walk_blocks/4`, which stops between blocks; a
      backfill whose pages are independent also stops inside a block and
      returns `{:within, height, after_tx_id}`, so a dense block is split
      into sub-batches, each committed and each a checkpoint the resume
      starts from (`start_cursor/2`, `blocks_after/2`, `within_block/2`).
    * **Adaptive sizes.** How many blocks a batch reads (`batch_limit/1`)
      and how many txs a page takes (`page_limit/1`, timed by `page_took/2`
      against `:page_ms`, default `:derivation_page_ms`, 2,000) are sized
      from the last one by `resize/5`: over the target, at least halve, to
      what would fit in half of it; under half the target, grow by a
      quarter; in between, hold. Shrink fast, grow slowly, and never above
      the configured `block_batch` or `tx_batch`.

  The deadline bounds the time; the sizes keep a batch from reading far
  more than it will use, and a page's transaction short. A batch always
  makes progress: its first block, and a block's first page, run whatever
  the clock says. `:clock` (a 0-arity fun returning milliseconds) stands in
  for the monotonic clock in tests.

  Options every backfill takes: `apply:` (default false), `pause_ms:`
  (default `config :bitblocks, :derivation_pause_ms`, 50),
  `statement_timeout_ms:` (default `:derivation_statement_timeout_ms`,
  60,000), `command:` (the command as typed, for the record), `on_batch:`
  (given the report after each batch), `chain_id:` (the
  `Bitblocks.BackfillChains` chain running this range) and `record:` (default
  true; false skips the `derivation_runs` row, for the one-block runs of
  `TxPipeline.CatchUp`, which would bury the operators' runs), and the
  pacing ones above: `batch_ms:`, `page_ms:`, `clock:` and `interrupt?:` (a
  0-arity fun; true ends the batch at the next block or page).
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.TxPipeline
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Repo

  @type report :: %{
          run_id: integer() | nil,
          derivation: String.t(),
          version: pos_integer(),
          applied: boolean(),
          from_height: integer() | nil,
          to_height: integer() | nil,
          blocks_examined: non_neg_integer(),
          rows_examined: non_neg_integer(),
          rows_changed: non_neg_integer(),
          rows_below_version: non_neg_integer(),
          details: map(),
          outcome: String.t(),
          error: String.t() | nil
        }

  @typedoc """
  A backfill: what it derives and at which version, its range, the cursor it
  starts from and `next`, which does one bounded batch from a cursor and
  returns `{:cont, cursor, report}` or `:done`.
  """
  @type spec :: %{
          derivation: String.t(),
          version: pos_integer(),
          from_height: integer() | nil,
          to_height: integer() | nil,
          cursor: term(),
          details: map(),
          next: (term(), report() -> {:cont, term(), report()} | :done)
        }

  @doc """
  Runs a backfill (`spec`) to the end, recording it in `derivation_runs`.
  Returns the report; `outcome` is `"ok"`, `"partial"`, `"failed"` or
  `"halted"` (`:after_batch` stopped it).
  Never raises for an error in a batch: it is recorded and returned.
  """
  @spec run(spec(), keyword()) :: report()
  def run(spec, opts) do
    applied = Keyword.get(opts, :apply, false)

    run =
      if Keyword.get(opts, :record, true) do
        Repo.insert!(%Run{
          derivation: spec.derivation,
          version: spec.version,
          from_height: spec.from_height,
          to_height: spec.to_height,
          applied: applied,
          chain_id: opts[:chain_id],
          command: opts[:command],
          details: spec.details,
          outcome: "running",
          started_at: DateTime.utc_now()
        })
      end

    report = %{
      run_id: run && run.id,
      derivation: spec.derivation,
      version: spec.version,
      applied: applied,
      from_height: spec.from_height,
      to_height: spec.to_height,
      blocks_examined: 0,
      rows_examined: 0,
      rows_changed: 0,
      rows_below_version: 0,
      details: spec.details,
      outcome: "running",
      error: nil
    }

    {report, batches, ending} =
      with_pace(opts, fn -> loop(spec, spec.cursor, report, 0, opts) end)

    report =
      case {ending, report.error} do
        {:halted, _} -> %{report | outcome: "halted"}
        {_, nil} -> %{report | outcome: "ok"}
        _ when batches > 0 -> %{report | outcome: "partial"}
        _ -> %{report | outcome: "failed"}
      end

    if run do
      run
      |> Ecto.Changeset.change(
        rows_examined: report.rows_examined,
        rows_changed: report.rows_changed,
        rows_below_version: report.rows_below_version,
        blocks_examined: report.blocks_examined,
        details: report.details,
        outcome: report.outcome,
        error: report.error,
        finished_at: DateTime.utc_now()
      )
      |> Repo.update!()
    end

    report
  end

  # Tail-recursive; only one batch at a time sits inside the rescue.
  defp loop(spec, cursor, report, batches, opts) do
    started = start_batch()

    case attempt(spec, cursor, report) do
      {:ok, :done} ->
        {report, batches, :done}

      {:ok, {:cont, cursor, next}} ->
        finish_batch(started, next.blocks_examined - report.blocks_examined)
        report = next

        if on_batch = opts[:on_batch], do: on_batch.(report)

        case after_batch(opts, cursor, report) do
          :halt -> {report, batches + 1, :halted}
          :cont -> loop(spec, cursor, report, batches + 1, opts)
        end

      {:error, message} ->
        Logger.error(
          "Derivations #{spec.derivation} v#{spec.version} stopped after #{batches} batch(es): #{message}"
        )

        {%{report | error: message}, batches, :error}
    end
  end

  # Called once a batch has returned, so everything it wrote is committed.
  defp after_batch(opts, cursor, report) do
    case opts[:after_batch] do
      nil -> :cont
      fun -> fun.(cursor, report)
    end
  end

  defp attempt(spec, cursor, report) do
    {:ok, spec.next.(cursor, report)}
  rescue
    e -> {:error, e |> describe(__STACKTRACE__) |> String.slice(0, 2_000)}
  end

  @doc false
  # The error as the run records it: the message, then where it happened
  # (the first frame in our code, which names the step: a page read, a
  # write, a tally) and, for a database error, the statement's head. A
  # statement timeout alone doesn't say which statement, or whether it was
  # slow or waiting on a lock (tx_types chain #12, 2026-11-10).
  def describe(e, stacktrace) do
    at =
      Enum.find_value(stacktrace, fn
        {mod, fun, arity, _} = entry when is_atom(mod) ->
          if String.starts_with?(Atom.to_string(mod), "Elixir.Bitblocks.") and
               mod != __MODULE__ do
            " at " <> Exception.format_mfa(mod, fun, arity) <> location(entry)
          end

        _ ->
          nil
      end)

    sql =
      case e do
        %{query: query} when is_binary(query) ->
          " in: " <> (query |> String.replace(~r/\s+/, " ") |> String.slice(0, 300))

        _ ->
          ""
      end

    Exception.message(e) <> (at || "") <> sql
  end

  defp location({_, _, _, meta}) do
    case {meta[:file], meta[:line]} do
      {file, line} when not is_nil(file) and not is_nil(line) -> " (#{file}:#{line})"
      _ -> ""
    end
  end

  ## Pacing (see the moduledoc)

  @pace {__MODULE__, :pace}
  @open_tx {__MODULE__, :open_tx}

  # The pace lives in the process dictionary of the process running the
  # batches, for the length of run/2, so a backfill asks time_up?/0 without
  # threading a deadline through every function. Outside run/2 there is no
  # pace: time is never up and the limits are the configured ones.
  defp with_pace(opts, fun) do
    outer = Process.get(@pace)

    Process.put(@pace, %{
      clock: Keyword.get(opts, :clock, &monotonic_ms/0),
      interrupt?: Keyword.get(opts, :interrupt?, fn -> false end),
      batch_ms: pace_ms(opts, :batch_ms, :derivation_batch_ms, 20_000),
      page_ms: pace_ms(opts, :page_ms, :derivation_page_ms, 2_000),
      deadline: nil,
      blocks: nil,
      blocks_max: nil,
      page: nil,
      page_max: nil
    })

    try do
      fun.()
    after
      if outer, do: Process.put(@pace, outer), else: Process.delete(@pace)
    end
  end

  defp pace_ms(opts, key, env, default) do
    Keyword.get_lazy(opts, key, fn -> Application.get_env(:bitblocks, env, default) end)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp start_batch do
    pace = Process.get(@pace)
    now = pace.clock.()
    Process.put(@pace, %{pace | deadline: now + pace.batch_ms})
    now
  end

  # Sizes the next batch from this one, when the backfill reads its blocks by
  # batch_limit/1: by the blocks it examined, or, when it examined none (a
  # batch of blocks it skipped), by the limit it took.
  defp finish_batch(started, blocks) do
    pace = Process.get(@pace)

    if pace.blocks do
      took = pace.clock.() - started
      units = if blocks > 0, do: blocks, else: pace.blocks

      Process.put(@pace, %{
        pace
        | blocks: resize(pace.blocks, took, units, pace.batch_ms, pace.blocks_max)
      })
    end

    :ok
  end

  @doc """
  The next size of a batch or page, from the last: it held `size` and took
  `took_ms` over `units` of work, against `target_ms`. Over the target it at
  least halves, to what would fit in half the target; at or under half the
  target it grows by a quarter (at least one); in between it holds. Always
  within 1..`max`.
  """
  @spec resize(pos_integer(), number(), non_neg_integer(), pos_integer(), pos_integer()) ::
          pos_integer()
  def resize(size, took_ms, units, target_ms, max) do
    next =
      cond do
        took_ms > target_ms ->
          fit = if units > 0, do: trunc(target_ms * units / (2 * took_ms)), else: 0
          min(div(size, 2), fit)

        took_ms * 2 <= target_ms ->
          size + max(1, div(size, 4))

        true ->
          size
      end

    next |> max(1) |> min(max)
  end

  @doc """
  True once the batch in flight has passed its deadline, or the run's
  `:interrupt?` says to stop (the node is stopping). Never true outside
  `run/2`.
  """
  @spec time_up?() :: boolean()
  def time_up? do
    case Process.get(@pace) do
      %{deadline: deadline, clock: clock, interrupt?: interrupt?} when is_integer(deadline) ->
        clock.() >= deadline or interrupt?.()

      _ ->
        false
    end
  end

  @doc "Now by the run's clock, in milliseconds: a page's start, for `page_took/2`."
  @spec now() :: integer()
  def now do
    case Process.get(@pace) do
      %{clock: clock} -> clock.()
      nil -> monotonic_ms()
    end
  end

  @doc "How many blocks this batch reads: at most `max` (the `block_batch` option)."
  @spec batch_limit(pos_integer()) :: pos_integer()
  def batch_limit(max), do: paced_size(:blocks, :blocks_max, max)

  @doc "How many txs this page takes: at most `max` (the `tx_batch` option)."
  @spec page_limit(pos_integer()) :: pos_integer()
  def page_limit(max), do: paced_size(:page, :page_max, max)

  defp paced_size(key, max_key, max) do
    case Process.get(@pace) do
      nil ->
        max

      pace ->
        size = min(Map.get(pace, key) || max, max)
        Process.put(@pace, pace |> Map.put(key, size) |> Map.put(max_key, max))
        size
    end
  end

  @doc """
  Records that a page of `rows`, taken at `page_limit/1`, started at
  `started` (`now/0`), and sizes the next page from it.
  """
  @spec page_took(non_neg_integer(), integer()) :: :ok
  def page_took(rows, started) do
    case Process.get(@pace) do
      %{page: size} = pace when is_integer(size) ->
        took = pace.clock.() - started
        Process.put(@pace, %{pace | page: resize(size, took, rows, pace.page_ms, pace.page_max)})

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Walks one batch of `blocks` from `cursor`, calling `fun.(block,
  after_tx_id, report)` per block and stopping between blocks once
  `time_up?/0`. The first block always runs, from the tx the cursor names
  when it is `{:within, height, after_tx_id}` at that block, else from the
  start (0). `fun` returns `{:done, report}`, or `{:within, after_tx_id,
  report}` when it stopped inside the block with its txs through that id
  committed. Returns the batch's `{:cont, cursor, report}`, the cursor
  `{height, id}` of the last block done whole, or `{:within, height,
  after_tx_id}`.
  """
  @spec walk_blocks(
          [map()],
          term(),
          report(),
          (map(), non_neg_integer(), report() ->
             {:done, report()} | {:within, integer(), report()})
        ) :: {:cont, term(), report()}
  def walk_blocks([first | _] = blocks, cursor, report, fun) do
    Enum.reduce_while(blocks, {:cont, cursor, report}, fn block, {:cont, at, report} ->
      if block != first and time_up?() do
        {:halt, {:cont, at, report}}
      else
        case fun.(block, within_block(cursor, block), report) do
          {:done, report} ->
            {:cont, {:cont, {block.height, block.id}, report}}

          {:within, after_tx_id, report} ->
            {:halt, {:cont, {:within, block.height, after_tx_id}, report}}
        end
      end
    end)
  end

  @doc """
  The tx id a block's walk starts after: the cursor's, when it stopped
  inside this block (`{:within, height, after_tx_id}`), else 0.
  """
  @spec within_block(term(), %{height: integer()}) :: non_neg_integer()
  def within_block({:within, height, after_tx_id}, %{height: height}), do: after_tx_id
  def within_block(_cursor, _block), do: 0

  @doc """
  Narrows a blocks query to the blocks after `cursor`, keyset on (height,
  id): `{after_height, after_id}`, or `{:within, height, _}`, which takes the
  block at `height` again (`blocks.height` is unique) to finish it.
  """
  @spec blocks_after(Ecto.Queryable.t(), term()) :: Ecto.Query.t()
  def blocks_after(query, {:within, height, _after_tx_id}),
    do: where(query, [b], b.height >= ^height)

  def blocks_after(query, {after_height, after_id}),
    do:
      where(
        query,
        [b],
        b.height > ^after_height or (b.height == ^after_height and b.id > ^after_id)
      )

  @doc """
  The cursor a block backfill starts from: before the range's first block,
  or, with `resume_after_tx:` (a chain's checkpoint inside a block), inside
  the block at `from_height`, after that tx.
  """
  @spec start_cursor(integer(), keyword()) :: term()
  def start_cursor(from_height, opts) do
    case opts[:resume_after_tx] do
      id when is_integer(id) and id > 0 -> {:within, from_height, id}
      _ -> {from_height - 1, 0}
    end
  end

  @doc """
  Runs `fun` in one short transaction under a `statement_timeout`
  (`:statement_timeout_ms`), so no statement of a backfill holds locks or
  runs unbounded. Returns `fun`'s result; raises on a timeout or error,
  which `run/2` records.

  With `watched: true` (a `Bitblocks.BackfillChains` job), it also notes the
  transaction's backend pid and start time in the process, for
  `open_transaction/1`, so a watchdog that kills this process can cancel
  the statement it left running.
  """
  @spec bounded(keyword(), (-> result)) :: result when result: term()
  def bounded(opts, fun) do
    ms = statement_timeout_ms(opts)

    {:ok, result} =
      Repo.transaction(
        fn ->
          Repo.query!("SET LOCAL statement_timeout = #{ms}")
          # Half the statement timeout for lock waits, so a wait on another
          # writer's row lock fails as 55P03 (lock timeout), not as a slow
          # statement (57014), and the recorded error says which it was.
          Repo.query!("SET LOCAL lock_timeout = #{div(ms, 2)}")
          if opts[:watched], do: note_transaction()

          try do
            fun.()
          after
            Process.delete(@open_tx)
          end
        end,
        timeout: ms + 5_000
      )

    result
  end

  # now() is the transaction's start, the same value pg_stat_activity shows
  # as xact_start, so the pair names this transaction and no later one on
  # the same connection.
  defp note_transaction do
    %{rows: [[pid, started]]} = Repo.query!("SELECT pg_backend_pid(), now()")
    put_open_transaction({pid, started})
  end

  @doc false
  # Notes `{backend_pid, xact_start}` as this process's open transaction, as
  # bounded/2 does under `watched: true`; a test of the watchdog notes one it
  # opened on its own connection.
  def put_open_transaction(open), do: Process.put(@open_tx, open)

  @doc """
  The bounded transaction `pid` has open, as `{backend_pid, xact_start}`,
  or nil: read from its process dictionary, so only while it is alive.
  """
  @spec open_transaction(pid()) :: {integer(), DateTime.t()} | nil
  def open_transaction(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> List.keyfind(dict, @open_tx, 0) |> then(&(&1 && elem(&1, 1)))
      nil -> nil
    end
  end

  @doc """
  Cancels the statement of a transaction a killed process left open, named
  by `open_transaction/1`, only while that backend is still in that same
  transaction: a connection already back in the pool has another
  `xact_start`, or none, and is left alone. Returns what it found:

    * `:cancelled`: the backend was running a statement in that
      transaction, and it was cancelled;
    * `:idle`: the backend was still in that transaction but between
      statements, so there was nothing to cancel (it aborts the transaction
      once the pool's disconnect reaches it);
    * `:gone`: the backend is no longer in that transaction;
    * `:none`: no transaction was open.
  """
  @spec cancel_transaction({integer(), DateTime.t()} | nil) ::
          :cancelled | :idle | :gone | :none
  def cancel_transaction(nil), do: :none

  def cancel_transaction({backend_pid, started}) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT CASE WHEN state = 'active' THEN pg_cancel_backend(pid) ELSE false END
        FROM pg_stat_activity
        WHERE pid = $1 AND xact_start = $2
        """,
        [backend_pid, started]
      )

    case rows do
      [[true]] -> :cancelled
      [[false]] -> :idle
      [] -> :gone
    end
  end

  @doc """
  A page's raw bytes, loaded under a byte budget (#123).

  `rows` are a page in its order, each with `:id` and `:raw_bytes`: the
  `octet_length` of the raw the row needs, or nil when it needs none (select
  it as `fragment("octet_length(?)", t.raw)`, which reads the TOAST header,
  not the bytes). Returns the longest prefix whose needed bytes fit
  `:page_raw_bytes` (`:derivation_page_raw_bytes`, 64 MB), always at least
  the first row, with `:raw` filled for the rows that need it. The caller
  carries on after the last row returned, so the rest come on later pages.

  A 1,000-row page with a few large inscriptions held gigabytes before this;
  now a page holds at most the budget, or one tx larger than it.

  It first collects this process's garbage: the previous page's binaries are
  dead by now, but a long-running job whose heap barely churns would
  otherwise keep them, off-heap, until a collection it rarely needs.
  """
  @spec fill_raw([map()], keyword()) :: [map()]
  def fill_raw(rows, opts \\ [])
  def fill_raw([], _opts), do: []

  def fill_raw(rows, opts) do
    :erlang.garbage_collect()
    page = within_bytes(rows, page_raw_bytes(opts))
    ids = for %{raw_bytes: n, id: id} <- page, n != nil, do: id

    raws =
      if ids == [],
        do: %{},
        else:
          Repo.all(
            from(t in Bitblocks.Chain.Transaction, where: t.id in ^ids, select: {t.id, t.raw})
          )
          |> Map.new()

    Enum.map(page, fn row ->
      row |> Map.delete(:raw_bytes) |> Map.put(:raw, row.raw_bytes && Map.get(raws, row.id))
    end)
  end

  @doc false
  # The longest prefix of `rows` whose `:raw_bytes` sum within `budget`,
  # never empty.
  def within_bytes([first | rest], budget) do
    {kept, _} =
      Enum.reduce_while(rest, {[first], first.raw_bytes || 0}, fn row, {kept, total} ->
        total = total + (row.raw_bytes || 0)
        if total > budget, do: {:halt, {kept, total}}, else: {:cont, {[row | kept], total}}
      end)

    Enum.reverse(kept)
  end

  defp page_raw_bytes(opts) do
    Keyword.get_lazy(opts, :page_raw_bytes, fn ->
      Application.get_env(:bitblocks, :derivation_page_raw_bytes, 64_000_000)
    end)
  end

  defp statement_timeout_ms(opts) do
    Keyword.get_lazy(opts, :statement_timeout_ms, fn ->
      Application.get_env(:bitblocks, :derivation_statement_timeout_ms, 60_000)
    end)
  end

  @doc "Sleeps `:pause_ms` after a write, so autovacuum keeps up."
  @spec pause(keyword()) :: :ok
  def pause(opts) do
    ms =
      Keyword.get_lazy(opts, :pause_ms, fn ->
        Application.get_env(:bitblocks, :derivation_pause_ms, 50)
      end)

    if ms > 0, do: Process.sleep(ms)
    :ok
  end

  @doc """
  Recent runs, newest first. Options: `limit:` (default 20), `derivation:`
  (a name, e.g. `"tallies"`).
  """
  @spec list_runs(keyword()) :: [Run.t()]
  def list_runs(opts \\ []) do
    query =
      from(r in Run,
        order_by: [desc: r.started_at, desc: r.id],
        limit: ^Keyword.get(opts, :limit, 20)
      )

    query =
      case opts[:derivation] do
        nil -> query
        name -> where(query, [r], r.derivation == ^to_string(name))
      end

    Repo.all(query)
  end

  @doc """
  Closes runs left `running` by a process that died (a deploy restart
  mid-backfill) as `abandoned`, with `finished_at` and a note in `error`.
  Their applied batches stay applied; a rerun of the range picks up the rest.

  `which` names the runs, so a live one is never closed by accident:
  `ids: [..]`, or `started_before: %DateTime{}`. Only `running` rows are
  closed; a named run that already finished is returned in `skipped`.
  A dry run by default; pass `apply: true` to write.
  """
  @spec close_abandoned(keyword(), keyword()) :: %{
          applied: boolean(),
          closed: [integer()],
          skipped: [integer()]
        }
  def close_abandoned(which, opts \\ []) do
    applied = Keyword.get(opts, :apply, false)

    named =
      cond do
        ids = which[:ids] -> from(r in Run, where: r.id in ^ids)
        before = which[:started_before] -> from(r in Run, where: r.started_at < ^before)
        true -> raise ArgumentError, "name the runs to close: ids: [..] or started_before:"
      end

    {running, finished} =
      named
      |> order_by([r], asc: r.id)
      |> select([r], {r.id, r.outcome})
      |> Repo.all()
      |> Enum.split_with(fn {_, outcome} -> outcome == "running" end)

    closed = Enum.map(running, &elem(&1, 0))

    if applied and closed != [] do
      from(r in Run, where: r.id in ^closed and r.outcome == "running")
      |> Repo.update_all(
        set: [
          outcome: "abandoned",
          error: "abandoned: the process ended before the run finished",
          finished_at: DateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        ]
      )
    end

    %{applied: applied, closed: closed, skipped: Enum.map(finished, &elem(&1, 0))}
  end

  @doc """
  What `GET /api/v1/status/derivations` answers: every step with its stage
  and version, the version of each stage and derivation (with the column it
  stamps and its backfill), and the latest runs. No secrets and no node
  address: run errors are cut to their first line with URLs and IPs removed.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    %{
      steps:
        for step <- TxPipeline.steps() do
          %{
            name: step.name(),
            stage: step.stage(),
            version: step.version(),
            description: step.description()
          }
        end,
      stages: Map.new([:chunk, :tx, :block], &{&1, TxPipeline.version(&1)}),
      derivations:
        for {name, d} <- TxPipeline.derivations() do
          %{
            name: name,
            version: TxPipeline.version(name),
            steps: Enum.map(d.steps, & &1.name()),
            stamp: d.stamp,
            block_stamp: Map.get(d, :block_stamp),
            backfill: d.backfill
          }
        end,
      runs: opts |> Keyword.put_new(:limit, 20) |> list_runs() |> Enum.map(&public/1)
    }
  end

  @doc "A run as the public status shows it."
  @spec public(Run.t()) :: map()
  def public(%Run{} = r) do
    %{
      id: r.id,
      derivation: r.derivation,
      version: r.version,
      chain_id: r.chain_id,
      from_height: r.from_height,
      to_height: r.to_height,
      applied: r.applied,
      rows_examined: r.rows_examined,
      rows_changed: r.rows_changed,
      rows_below_version: r.rows_below_version,
      blocks_examined: r.blocks_examined,
      details: r.details,
      outcome: r.outcome,
      error: scrub(r.error),
      command: r.command,
      started_at: r.started_at,
      finished_at: r.finished_at
    }
  end

  defp scrub(nil), do: nil

  defp scrub(error) do
    error
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.replace(~r{\b[a-z][a-z0-9+.-]*://\S+}i, "[url]")
    |> String.replace(~r/\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b/, "[ip]")
    |> String.slice(0, 300)
  end
end
