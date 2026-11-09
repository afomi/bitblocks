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
    * prints progress through `:on_batch`.

  The batch function bounds its own statements with `bounded/2` (a short
  transaction under a `statement_timeout`) and calls `pause/1` after each
  write, so autovacuum keeps up with the non-HOT updates on `transactions`.

  Options every backfill takes: `apply:` (default false), `pause_ms:`
  (default `config :bitblocks, :derivation_pause_ms`, 50),
  `statement_timeout_ms:` (default `:derivation_statement_timeout_ms`,
  60,000), `command:` (the command as typed, for the record), `on_batch:`
  (given the report after each batch), `chain_id:` (the
  `Bitblocks.BackfillChains` chain running this range) and `record:` (default
  true; false skips the `derivation_runs` row, for the one-block runs of
  `TxPipeline.CatchUp`, which would bury the operators' runs).
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
  Returns the report; `outcome` is `"ok"`, `"partial"` or `"failed"`.
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

    {report, batches} = loop(spec, spec.cursor, report, 0, opts)

    report =
      case report.error do
        nil -> %{report | outcome: "ok"}
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
    case attempt(spec, cursor, report) do
      {:ok, :done} ->
        {report, batches}

      {:ok, {:cont, cursor, report}} ->
        if on_batch = opts[:on_batch], do: on_batch.(report)
        loop(spec, cursor, report, batches + 1, opts)

      {:error, message} ->
        Logger.error(
          "Derivations #{spec.derivation} v#{spec.version} stopped after #{batches} batch(es): #{message}"
        )

        {%{report | error: message}, batches}
    end
  end

  defp attempt(spec, cursor, report) do
    {:ok, spec.next.(cursor, report)}
  rescue
    e -> {:error, e |> Exception.message() |> String.slice(0, 2_000)}
  end

  @doc """
  Runs `fun` in one short transaction under a `statement_timeout`
  (`:statement_timeout_ms`), so no statement of a backfill holds locks or
  runs unbounded. Returns `fun`'s result; raises on a timeout or error,
  which `run/2` records.
  """
  @spec bounded(keyword(), (-> result)) :: result when result: term()
  def bounded(opts, fun) do
    ms = statement_timeout_ms(opts)

    {:ok, result} =
      Repo.transaction(
        fn ->
          Repo.query!("SET LOCAL statement_timeout = #{ms}")
          fun.()
        end,
        timeout: ms + 5_000
      )

    result
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
