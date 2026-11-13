defmodule Bitblocks.Sync do
  @moduledoc """
  The sync loop's one coverage number and its work order.

  `complete_through/0` is the highest height H such that every block from
  genesis through H is `completed`: its txid list rebuilt the header's
  merkleroot and every one of its transactions is stored. It is computed,
  never stored, so it can only be as true as the rows it reads.

  Work goes strictly upward from `complete_through + 1`. `dispatch/0`, run
  by the one `Sync.Coordinator`, keeps a `FetchTransactionsWorker` job for
  each of `concurrency/0` worker slots, given to the lowest incomplete
  blocks. Each job owns one block (unique on the block hash), so two
  processes never work the same block, and a block that keeps failing holds
  its slot and its place instead of being skipped.

  See docs/SYNCING.md.
  """

  import Ecto.Query

  alias Bitblocks.Repo
  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Sync.Settings
  alias Bitblocks.Workers.FetchTransactionsWorker

  @worker "Bitblocks.Workers.FetchTransactionsWorker"
  @live_states ~w(available scheduled executing retryable)
  @control_topic "sync:control"
  @dispatch_lock 728_193_042

  # Every state but "completed". A lateral probe per state on
  # blocks_sync_state_height_index finds the lowest incomplete blocks in
  # microseconds; `sync_state <> 'completed'` would walk the height index
  # through every completed block first.
  @incomplete_states ~w(pending header_only header_synced txs_queued txs_syncing failed)

  @doc """
  The sync's position: our highest stored header (`tip`), `complete_through`,
  and the `target` block that holds it back (nil when complete to the tip).
  """
  @spec status() :: %{
          tip: integer() | nil,
          complete_through: integer(),
          target: integer() | nil
        }
  def status do
    tip = tip()
    through = complete_through(tip)
    %{tip: tip, complete_through: through, target: if(tip && through < tip, do: through + 1)}
  end

  @doc "Our highest stored header, or nil with no blocks."
  @spec tip() :: integer() | nil
  def tip do
    Repo.one(from(b in Block, order_by: [desc: b.height], limit: 1, select: b.height))
  end

  @doc """
  The highest height H such that blocks 0..H are all stored and `completed`;
  -1 when block 0 isn't. A missing header counts as incomplete.
  """
  @spec complete_through(integer() | nil) :: integer()
  def complete_through(tip \\ tip())
  def complete_through(nil), do: -1

  def complete_through(tip) do
    bound =
      case lowest_incomplete(1) do
        [%{height: h}] -> h
        [] -> tip + 1
      end

    first_missing_below(bound) - 1
  end

  # Short of rows by design: genesis's coinbase isn't served as a tx, and these
  # two duplicate the coinbases of 91,880 and 91,842, which a unique txid can't
  # hold twice (BIP30).
  @short_by_design [0, 91_722, 91_812]
  @reopen_batch 500

  @doc """
  Reopens `completed` blocks in `from..to` that hold fewer rows than their
  `num_tx`, so the sync loop refills them when it reaches them, in order.
  Blocks above `complete_through` wait their turn and cost nothing until then;
  reopening one below it pulls `complete_through` back to it.

  A dry run unless `apply: true`. Reads by height and `block_hash` through
  their indexes, `#{@reopen_batch}` blocks at a time, so a range is cheap
  whatever the size of `transactions`. A range is required: the three heights
  in `@short_by_design` are skipped, but anything else short gets reopened.
  """
  @spec reopen_short_blocks(integer(), integer(), keyword()) :: %{
          applied: boolean(),
          examined: non_neg_integer(),
          short: non_neg_integer(),
          rows_missing: non_neg_integer(),
          reopened: non_neg_integer(),
          lowest: integer() | nil,
          highest: integer() | nil
        }
  def reopen_short_blocks(from, to, opts \\ []) when from <= to do
    applied = Keyword.get(opts, :apply, false)

    report = %{
      applied: applied,
      examined: 0,
      short: 0,
      rows_missing: 0,
      reopened: 0,
      lowest: nil,
      highest: nil
    }

    reopen_batch(from, to, applied, report)
  end

  defp reopen_batch(from, to, applied, report) do
    blocks =
      Repo.all(
        from(b in Block,
          where: b.height >= ^from and b.height <= ^to,
          where: b.sync_state == "completed",
          where: b.height not in @short_by_design,
          order_by: b.height,
          limit: @reopen_batch,
          select: %{hash: b.hash, height: b.height, num_tx: b.num_tx}
        )
      )

    case blocks do
      [] ->
        report

      _ ->
        stored = stored_counts(blocks)
        short = Enum.filter(blocks, &(Map.get(stored, &1.hash, 0) < (&1.num_tx || 0)))
        report = tally(report, blocks, short, stored, applied)
        reopen_batch(List.last(blocks).height + 1, to, applied, report)
    end
  end

  defp stored_counts(blocks) do
    hashes = Enum.map(blocks, & &1.hash)

    Repo.all(
      from(t in Transaction,
        where: t.block_hash in ^hashes,
        group_by: t.block_hash,
        select: {t.block_hash, count()}
      )
    )
    |> Map.new()
  end

  defp tally(report, blocks, short, stored, applied) do
    heights = Enum.map(short, & &1.height)
    missing = Enum.sum(Enum.map(short, &(&1.num_tx - Map.get(stored, &1.hash, 0))))

    %{
      report
      | examined: report.examined + length(blocks),
        short: report.short + length(short),
        rows_missing: report.rows_missing + missing,
        reopened: report.reopened + if(applied, do: reopen(short), else: 0),
        lowest: report.lowest || List.first(heights),
        highest: List.last(heights) || report.highest
    }
  end

  defp reopen(blocks) do
    hashes = Enum.map(blocks, & &1.hash)

    {reopened, _} =
      Repo.update_all(
        from(b in Block, where: b.hash in ^hashes and b.sync_state == "completed"),
        set: [
          sync_state: "header_synced",
          tx_sync_completed_at: nil,
          # chain tiles (#48) find changed blocks by updated_at
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        ]
      )

    reopened
  end

  @doc """
  The lowest `n` stored blocks that are not completed, ascending, as
  `%{height: h, hash: hash, num_tx: n}`.
  """
  @spec lowest_incomplete(pos_integer()) :: [
          %{height: integer(), hash: String.t(), num_tx: integer() | nil}
        ]
  def lowest_incomplete(n) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT b.height, b.hash, b.num_tx
        FROM unnest($1::text[]) AS s(state)
        CROSS JOIN LATERAL (
          SELECT height, hash, num_tx FROM blocks
          WHERE sync_state = s.state
          ORDER BY height
          LIMIT $2
        ) b
        ORDER BY b.height
        LIMIT $2
        """,
        [@incomplete_states, n]
      )

    for [height, hash, num_tx] <- rows, do: %{height: height, hash: hash, num_tx: num_tx}
  end

  @doc """
  The lowest height below `bound` with no stored block, or `bound` when
  0..bound-1 are all stored. Heights are unique, so a full count means no
  gap; only then is the gap looked for, stopping at the first.
  """
  @spec first_missing_below(non_neg_integer()) :: non_neg_integer()
  def first_missing_below(bound) when bound <= 0, do: 0

  def first_missing_below(bound) do
    stored = Repo.one(from(b in Block, where: b.height < ^bound, select: count()))

    if stored == bound do
      bound
    else
      %{rows: [[missing]]} =
        Repo.query!(
          """
          SELECT CASE
            WHEN NOT EXISTS (SELECT 1 FROM blocks WHERE height = 0) THEN 0
            ELSE (
              SELECT b.height + 1 FROM blocks b
              WHERE b.height < $1
                AND NOT EXISTS (SELECT 1 FROM blocks n WHERE n.height = b.height + 1)
              ORDER BY b.height
              LIMIT 1
            )
          END
          """,
          [bound]
        )

      min(missing || bound, bound)
    end
  end

  # -- Concurrency -------------------------------------------------------------

  @doc """
  The most blocks this node can work at once, and what binds it:
  `{max, reason}`, the smallest of CPU cores, database connections left
  after a reserve for web requests and header sync, and the node's RPC
  threads (`config :bitblocks, :sync_rpc_limit`, env `SYNC_RPC_LIMIT`,
  default 4 like bitcoind's `rpcthreads`).
  """
  @spec concurrency_limit() :: {pos_integer(), String.t()}
  def concurrency_limit do
    pool = Repo.config()[:pool_size] || 10
    reserve = Application.get_env(:bitblocks, :sync_pool_reserve, 5)

    [
      {System.schedulers_online(), "CPU cores"},
      {pool - reserve, "database connections"},
      {Application.get_env(:bitblocks, :sync_rpc_limit, 4), "node RPC threads"}
    ]
    |> Enum.min_by(&elem(&1, 0))
    |> then(fn {n, reason} -> {max(n, 1), reason} end)
  end

  @doc """
  Blocks worked at once: the persisted choice, else `config :bitblocks,
  :sync_workers`, clamped to `concurrency_limit/0`.
  """
  @spec concurrency() :: pos_integer()
  def concurrency do
    chosen =
      case Repo.get(Settings, 1) do
        %Settings{concurrency: n} -> n
        nil -> Application.get_env(:bitblocks, :sync_workers, 1)
      end

    clamp(chosen)
  end

  @doc """
  Persists a new concurrency, clamped to 1..`concurrency_limit/0`, and tells
  the coordinator. Returns `{:ok, applied}`.
  """
  @spec set_concurrency(integer()) :: {:ok, pos_integer()}
  def set_concurrency(n) when is_integer(n) do
    applied = clamp(n)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {:ok, _} =
      serialize_dispatch(fn ->
        Repo.insert!(
          %Settings{id: 1, concurrency: applied, inserted_at: now, updated_at: now},
          on_conflict: [set: [concurrency: applied, updated_at: now]],
          conflict_target: :id
        )
      end)

    Phoenix.PubSub.broadcast(Bitblocks.PubSub, @control_topic, {:concurrency, applied})
    {:ok, applied}
  end

  @doc "The lowest failed blocks, with their error. Served by blocks_sync_state_height_index."
  @spec failed_blocks(pos_integer()) :: [map()]
  def failed_blocks(limit \\ 20) do
    from(b in Block,
      where: b.sync_state == "failed",
      order_by: [asc: b.height],
      limit: ^limit,
      select: %{height: b.height, attempts: b.tx_sync_attempts, error: b.tx_sync_error}
    )
    |> Repo.all()
  end

  @doc """
  The height the sync stops at, by plan (`:sync_stop_at_height`, prod
  400,000 since 2026-11-13; `SYNC_STOP_AT_HEIGHT` overrides it, `none`
  clears it), or nil to sync to the tip. No block above it is dispatched;
  header sync carries on to the tip, so the chain's shape stays current.
  See docs/STORAGE_PLAN.md.
  """
  @spec stop_height() :: non_neg_integer() | nil
  def stop_height, do: Application.get_env(:bitblocks, :sync_stop_at_height)

  @doc "True once `complete_through` has reached `stop_height/0`."
  @spec stopped?(integer() | nil) :: boolean()
  def stopped?(through \\ complete_through()) do
    stop = stop_height()
    is_integer(stop) and is_integer(through) and through >= stop
  end

  @doc """
  True while an operator has paused the loop: the coordinator dispatches no
  new block jobs, and blocks already dispatched finish. Persisted in
  `sync_settings`, so it holds across restarts, deploys and leader changes.
  """
  @spec paused?() :: boolean()
  def paused? do
    match?(%Settings{paused: true}, Repo.get(Settings, 1))
  end

  @doc """
  Pauses or resumes the loop, keeping the concurrency choice, and tells the
  coordinator. Returns `{:ok, paused}`.
  """
  @spec set_paused(boolean()) :: {:ok, boolean()}
  def set_paused(paused) when is_boolean(paused) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {:ok, _} =
      serialize_dispatch(fn ->
        Repo.insert!(
          %Settings{
            id: 1,
            concurrency: concurrency(),
            paused: paused,
            inserted_at: now,
            updated_at: now
          },
          on_conflict: [set: [paused: paused, updated_at: now]],
          conflict_target: :id
        )
      end)

    Phoenix.PubSub.broadcast(Bitblocks.PubSub, @control_topic, {:paused, paused})
    {:ok, paused}
  end

  @doc "The PubSub topic the coordinator listens on for control changes."
  def control_topic, do: @control_topic

  defp clamp(n) do
    {max, _} = concurrency_limit()
    n |> max(1) |> min(max)
  end

  # -- Dispatch ----------------------------------------------------------------

  @doc """
  The live block jobs (queued, running or backing off), lowest height first:
  `%{hash, height, slot, state, attempt, scheduled_at, node, held}`.

  A run job (see `dispatch/1`) is reported at the block it is on now, its
  first member not yet completed, and `held` lists every block it owns, so
  dispatch never gives one of them to another slot.
  """
  @spec live_jobs() :: [map()]
  def live_jobs do
    jobs =
      from(j in Oban.Job,
        where: j.worker == ^@worker and j.state in ^@live_states,
        select: %{
          hash: fragment("?->>'block_hash'", j.args),
          run: fragment("?->'run'", j.args),
          slot: fragment("(?->>'slot')::int", j.meta),
          state: j.state,
          scheduled_at: j.scheduled_at,
          attempted_by: j.attempted_by
        }
      )
      |> Repo.all()

    members = Enum.flat_map(jobs, &held(&1))

    blocks =
      from(b in Block, where: b.hash in ^members, select: {b.hash, {b.height, b.sync_state}})
      |> Repo.all()
      |> Map.new()

    jobs
    |> Enum.map(fn job ->
      held = held(job)

      current =
        Enum.find(held, List.last(held), fn hash ->
          match?({_, state} when state != "completed", blocks[hash])
        end)

      job
      |> Map.merge(%{
        hash: current,
        height: blocks |> Map.get(current, {nil, nil}) |> elem(0),
        held: held,
        node: List.first(job.attempted_by || [])
      })
      |> Map.drop([:attempted_by, :run])
    end)
    |> Enum.sort_by(&(&1.height || -1))
  end

  defp held(%{run: [_ | _] = run}), do: run
  defp held(%{hash: hash}), do: [hash]

  @doc """
  Fills free worker slots with the lowest incomplete blocks that have no
  live job, ascending. A block keeps its job (and slot) until it completes,
  so it is never assigned twice; when concurrency shrinks, live jobs finish
  and their slots are not refilled. Returns the number of jobs queued.

  Small blocks go in runs: when the next blocks for a slot each have at most
  `:sync_run_small_txs` txs, one job takes up to `:sync_run_max_blocks` of
  them (and at most `:sync_run_max_txs` txs in all), in height order, so the
  hand-off between jobs is paid once per run instead of once per block. The
  run's time is bounded by `:tx_fetch_run_ms` like any job, and its blocks are
  worked one at a time, so the limits keep runs short, not memory low.
  Near height 157,000 the median block has 31 txs and the largest 379.
  """
  @spec dispatch(pos_integer() | nil) :: non_neg_integer()
  def dispatch(requested \\ nil) do
    # A leader handover can overlap. Count capacity and insert whole runs in
    # one transaction, across all instances, rather than relying on uniqueness
    # of a run's first block to protect the rest of its members.
    {:ok, count} =
      serialize_dispatch(fn ->
        chosen = concurrency()
        slots = if is_integer(requested), do: min(max(requested, 1), chosen), else: chosen
        if paused?(), do: 0, else: dispatch_window(slots)
      end)

    count
  end

  defp serialize_dispatch(fun) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@dispatch_lock])
      fun.()
    end)
  end

  defp dispatch_window(n) do
    live = live_jobs()
    free = n - length(live)

    if free <= 0 do
      0
    else
      held = live |> Enum.flat_map(& &1.held) |> MapSet.new()
      free_slots = Enum.to_list(1..n) -- Enum.map(live, & &1.slot)

      n
      |> candidates_in_window()
      |> Enum.reject(&MapSet.member?(held, &1.hash))
      |> plan_runs(free, run_limits())
      |> Enum.zip(free_slots)
      |> Enum.count(fn {run, slot} ->
        match?({:ok, %{conflict?: false}}, Oban.insert(job_for(run, slot)))
      end)
    end
  end

  # Pin the window to the contiguous checkpoint, including blocks already
  # held by jobs. A faster slot must not keep moving away from a stalled one.
  # Only this bounded height range is read, and a missing header ends it.
  defp candidates_in_window(slots) do
    first = complete_through() + 1
    last = first + slots * run_limits().max_blocks - 1
    # Nothing above the planned stop (stop_height/0); past it the window is empty.
    last = if is_integer(stop_height()), do: min(last, stop_height()), else: last

    from(b in Block,
      where: b.height >= ^first and b.height <= ^last,
      order_by: b.height,
      select: %{height: b.height, hash: b.hash, num_tx: b.num_tx, sync_state: b.sync_state}
    )
    |> Repo.all()
    |> Enum.with_index(first)
    |> Enum.take_while(fn {block, expected} -> block.height == expected end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&(&1.sync_state == "completed"))
  end

  defp job_for([%{hash: hash}], slot),
    do: FetchTransactionsWorker.new(%{block_hash: hash}, meta: %{slot: slot})

  defp job_for([%{hash: first} | _] = run, slot),
    do:
      FetchTransactionsWorker.new(%{block_hash: first, run: Enum.map(run, & &1.hash)},
        meta: %{slot: slot}
      )

  @doc """
  Splits ascending candidates into at most `slots` jobs: a run of small
  blocks while they fit the limits, else one block alone. Pure, for tests.
  """
  @spec plan_runs([map()], non_neg_integer(), map()) :: [[map()]]
  def plan_runs(_candidates, 0, _limits), do: []
  def plan_runs([], _slots, _limits), do: []

  def plan_runs([first | rest] = candidates, slots, limits) do
    if small?(first, limits) do
      {run, rest} = take_run(candidates, limits, [], 0)
      [run | plan_runs(rest, slots - 1, limits)]
    else
      [[first] | plan_runs(rest, slots - 1, limits)]
    end
  end

  defp take_run([c | rest] = candidates, limits, acc, txs) do
    if length(acc) < limits.max_blocks and small?(c, limits) and txs + c.num_tx <= limits.max_txs do
      take_run(rest, limits, [c | acc], txs + c.num_tx)
    else
      {Enum.reverse(acc), candidates}
    end
  end

  defp take_run([], _limits, acc, _txs), do: {Enum.reverse(acc), []}

  defp small?(%{num_tx: n}, limits), do: is_integer(n) and n > 0 and n <= limits.small_txs
  defp small?(_, _limits), do: false

  @doc "The run limits, from config (`:sync_run_max_blocks`, `:sync_run_max_txs`, `:sync_run_small_txs`)."
  def run_limits do
    %{
      max_blocks: Application.get_env(:bitblocks, :sync_run_max_blocks, 50),
      max_txs: Application.get_env(:bitblocks, :sync_run_max_txs, 20_000),
      small_txs: Application.get_env(:bitblocks, :sync_run_small_txs, 1_000)
    }
  end

  # -- The table ---------------------------------------------------------------

  @doc """
  The sync's state for /syncing and /sync: coverage, concurrency and its
  limit, and a table of blocks in ascending height. The rows are the
  `complete_through` block, the blocks with live jobs, and the next
  `next` incomplete blocks waiting for a slot.
  """
  @spec overview(non_neg_integer()) :: map()
  def overview(next \\ 5) do
    %{tip: tip, complete_through: through, target: target} = status()
    live = live_jobs()
    {max, reason} = concurrency_limit()
    held = live |> Enum.flat_map(& &1.held) |> MapSet.new()

    waiting =
      (next + length(live))
      |> lowest_incomplete()
      |> Enum.reject(&MapSet.member?(held, &1.hash))
      |> Enum.take(next)

    jobs = Map.new(live, &{&1.hash, &1})
    hashes = Enum.map(live, & &1.hash) ++ Enum.map(waiting, & &1.hash)

    rows =
      from(b in Block,
        where: b.hash in ^hashes or b.height == ^through,
        order_by: [asc: b.height],
        select: %{
          hash: b.hash,
          height: b.height,
          num_tx: b.num_tx,
          sync_state: b.sync_state,
          failures: b.tx_sync_attempts,
          error: b.tx_sync_error
        }
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        job = Map.get(jobs, row.hash)

        Map.merge(row, %{
          slot: job && job.slot,
          node: job && job.node,
          job_state: job && job.state,
          next_retry_at:
            job && job.state == "scheduled" && (row.failures || 0) > 0 && job.scheduled_at
        })
      end)

    %{
      tip: tip,
      complete_through: through,
      target: target,
      concurrency: concurrency(),
      paused: paused?(),
      max_concurrency: max,
      limit_reason: reason,
      in_use: length(live),
      rows: rows
    }
  end
end
