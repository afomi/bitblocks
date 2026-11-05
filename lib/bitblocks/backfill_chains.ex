defmodule Bitblocks.BackfillChains do
  @moduledoc """
  Runs a backfill as Oban jobs, one range at a time, so it survives a deploy
  and needs no connection held open (`docs/DERIVED_DATA.md`).

  The `derivation_chains` row is the chain's state. A job
  (`Bitblocks.Workers.BackfillChainWorker`) takes the range at `next_from`,
  runs the ordinary backfill over it, moves `next_from` on and enqueues the
  next job.

  A restart kills a job mid-range and Lifeline rescues it after `rescue_after`.
  The rerun closes the run the dead job left `running` and picks up the rows
  still below the version.

  Lifeline can also rescue a job that is still alive, when a range outlasts
  `rescue_after`. Each batch beats the chain's heartbeat, so the rescued copy
  sees a live job and snoozes; when it wakes, `next_from` has moved on and it
  stops.

  A dry run's counts live in its `derivation_runs` rows, and `status/1` sums
  them, so they survive a restart too.
  """

  import Ecto.Query

  alias Bitblocks.Chain.TxPipeline.{
    Backfill,
    ScriptAnalysisBackfill,
    TxStepsBackfill,
    TxTypesBackfill
  }

  alias Bitblocks.Chain.{Transaction, TxSizeBackfill}
  alias Bitblocks.Derivations
  alias Bitblocks.Derivations.{BackfillChain, Run}
  alias Bitblocks.Repo
  alias Bitblocks.Workers.BackfillChainWorker

  @derivations ~w(script_analysis tx_steps tallies tx_types tx_size)

  # What a job passes on to the backfill. Named here because opts come back
  # from JSON, and arbitrary strings must never become atoms.
  @backfill_opts ~w(force pause_ms statement_timeout_ms block_batch tx_batch batch_size id_window)a

  @height_step 10_000
  @id_step 1_000_000

  # A beat older than this means the job died. Well above a batch's length,
  # and below Lifeline's 30 minutes, so a rescued job finds a dead one stale.
  @heartbeat_stale_ms :timer.minutes(15)

  def derivations, do: @derivations

  @doc """
  Starts a chain over `from..to`: block heights, or tx ids for `tx_size`.
  A dry run unless `apply: true`. `step:` sets how much one job takes (10,000
  heights, 1,000,000 ids); the other options are the backfill's own.

  Refuses a derivation that already has a chain running or paused, so a second
  start can't work the same rows alongside the first.
  """
  @spec start(String.t(), integer(), integer(), keyword()) ::
          {:ok, BackfillChain.t()} | {:error, term()}
  def start(derivation, from, to, opts \\ []) when derivation in @derivations do
    Repo.transaction(fn ->
      lock_derivation(derivation)

      case active(derivation) do
        nil -> insert_chain(derivation, from, to, opts)
        chain -> Repo.rollback({:already_active, chain.id})
      end
    end)
  end

  defp lock_derivation(derivation) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["derivation_chain:" <> derivation])
  end

  defp insert_chain(derivation, from, to, opts) do
    chain =
      Repo.insert!(%BackfillChain{
        derivation: derivation,
        applied: Keyword.get(opts, :apply, false),
        range_from: from,
        range_to: to,
        range_step: Keyword.get(opts, :step, default_step(derivation)),
        next_from: from,
        opts: opts |> Keyword.take(@backfill_opts) |> Map.new()
      })

    enqueue(chain)
    chain
  end

  defp default_step("tx_size"), do: @id_step
  defp default_step(_), do: @height_step

  @doc "The ids a whole-table chain covers: every tx row now stored."
  @spec tx_id_range() :: {integer(), integer()}
  def tx_id_range, do: {1, Repo.aggregate(Transaction, :max, :id) || 0}

  defp active(derivation) do
    Repo.one(
      from(c in BackfillChain,
        where: c.derivation == ^derivation and c.status in ["running", "paused"],
        limit: 1
      )
    )
  end

  defp enqueue(chain) do
    %{"chain_id" => chain.id, "from" => chain.next_from}
    |> BackfillChainWorker.new()
    |> Oban.insert!()
  end

  @doc "Stops the chain once the range in flight finishes."
  @spec pause(integer()) :: {:ok, BackfillChain.t()} | {:error, term()}
  def pause(id), do: move(id, ["running"], "paused")

  @doc "Stops the chain for good once the range in flight finishes."
  @spec cancel(integer()) :: {:ok, BackfillChain.t()} | {:error, term()}
  def cancel(id), do: move(id, ["running", "paused", "failed"], "cancelled")

  @doc """
  Carries on from `next_from`: a paused or failed chain, or a running one whose
  job was lost. A live job is safe from a second start: its copy snoozes.
  """
  @spec resume(integer()) :: {:ok, BackfillChain.t()} | {:error, term()}
  def resume(id) do
    with {:ok, chain} <- move(id, ["running", "paused", "failed"], "running") do
      enqueue(chain)
      {:ok, chain}
    end
  end

  defp move(id, from_statuses, status) do
    case Repo.get(BackfillChain, id) do
      nil ->
        {:error, :not_found}

      %{status: current} = chain ->
        if current in from_statuses do
          chain
          |> Ecto.Changeset.change(status: status, error: nil, finished_at: finished_at(status))
          |> Repo.update()
        else
          {:error, {:cannot_move, current, status}}
        end
    end
  end

  defp finished_at("cancelled"), do: DateTime.utc_now()
  defp finished_at(_), do: nil

  @doc """
  One job's work: the range at `from`, then the next job. Returns what the
  worker returns to Oban.
  """
  @spec run_range(integer(), integer(), boolean()) ::
          :ok | {:snooze, pos_integer()} | {:cancel, term()} | {:error, term()}
  def run_range(id, from, last_attempt?) do
    chain = Repo.get(BackfillChain, id)

    cond do
      is_nil(chain) -> {:cancel, :no_chain}
      chain.status != "running" -> {:cancel, {:chain, chain.status}}
      chain.next_from != from -> {:cancel, :superseded}
      alive?(chain) -> {:snooze, 120}
      true -> work(chain, from, last_attempt?)
    end
  end

  defp alive?(%{heartbeat_at: nil}), do: false

  defp alive?(%{heartbeat_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at, :millisecond) < @heartbeat_stale_ms

  defp work(chain, from, last_attempt?) do
    close_dead_runs(chain)
    beat(chain.id)

    to = min(from + chain.range_step - 1, chain.range_to)
    report = run_backfill(chain, from, to)
    clear_heartbeat(chain.id)

    case report.outcome do
      "ok" -> advance(chain, from, to)
      _ -> retry_or_fail(chain, report.error, last_attempt?)
    end
  end

  # Past the alive?/1 check, nothing of this chain is working, so a run still
  # `running` lost its process.
  defp close_dead_runs(chain) do
    ids =
      Repo.all(
        from(r in Run, where: r.chain_id == ^chain.id and r.outcome == "running", select: r.id)
      )

    if ids != [], do: Derivations.close_abandoned([ids: ids], apply: true)
  end

  defp run_backfill(chain, from, to) do
    opts =
      for {key, value} <- chain.opts, atom = allowed(key), atom != nil do
        {atom, value}
      end ++
        [
          apply: chain.applied,
          chain_id: chain.id,
          command: "chain ##{chain.id} #{chain.derivation} #{from}..#{to}",
          on_batch: fn _ -> beat(chain.id) end
        ]

    backfill(chain.derivation, from, to, opts)
  end

  defp allowed(key), do: Enum.find(@backfill_opts, &(Atom.to_string(&1) == key))

  defp backfill("script_analysis", from, to, opts), do: ScriptAnalysisBackfill.run(from, to, opts)
  defp backfill("tx_steps", from, to, opts), do: TxStepsBackfill.run(from, to, opts)
  defp backfill("tallies", from, to, opts), do: Backfill.run(from, to, opts)
  defp backfill("tx_types", from, to, opts), do: TxTypesBackfill.run(from, to, opts)

  defp backfill("tx_size", from, to, opts),
    do: TxSizeBackfill.run(Keyword.merge(opts, from_id: from, to_id: to))

  defp advance(chain, from, to) do
    done? = to >= chain.range_to

    # Keyed on next_from, so only one copy of a job moves the chain on.
    {moved, _} =
      Repo.update_all(
        from(c in BackfillChain, where: c.id == ^chain.id and c.next_from == ^from),
        set: [next_from: to + 1]
      )

    if moved == 1 do
      if done?, do: finish(chain.id), else: continue(chain.id)
    end

    :ok
  end

  defp finish(id) do
    Repo.update_all(
      from(c in BackfillChain, where: c.id == ^id and c.status == "running"),
      set: [status: "done", finished_at: DateTime.utc_now()]
    )
  end

  # A pause or cancel during the range landed on the row: read it fresh.
  defp continue(id) do
    case Repo.get!(BackfillChain, id) do
      %{status: "running"} = chain -> enqueue(chain)
      _ -> :ok
    end
  end

  defp retry_or_fail(chain, error, true) do
    Repo.update_all(
      from(c in BackfillChain, where: c.id == ^chain.id and c.status == "running"),
      set: [status: "failed", error: error, finished_at: DateTime.utc_now()]
    )

    {:error, error}
  end

  defp retry_or_fail(_chain, error, false), do: {:error, error}

  defp beat(id) do
    Repo.update_all(
      from(c in BackfillChain, where: c.id == ^id),
      set: [heartbeat_at: DateTime.utc_now()]
    )
  end

  defp clear_heartbeat(id) do
    Repo.update_all(from(c in BackfillChain, where: c.id == ^id), set: [heartbeat_at: nil])
  end

  @doc """
  The chain and its ranges so far: the rows the runs examined and changed,
  summed, with `details` summed key by key. `nil` for an unknown id.
  """
  @spec status(integer()) :: map() | nil
  def status(id) do
    case Repo.get(BackfillChain, id) do
      nil -> nil
      chain -> summarize(chain)
    end
  end

  @doc "The latest chains, newest first."
  @spec list(pos_integer()) :: [BackfillChain.t()]
  def list(limit \\ 10) do
    Repo.all(from(c in BackfillChain, order_by: [desc: c.id], limit: ^limit))
  end

  defp summarize(chain) do
    runs = Repo.all(from(r in Run, where: r.chain_id == ^chain.id, order_by: [asc: r.id]))
    counted = Enum.filter(runs, &(&1.outcome == "ok"))

    %{
      chain: chain,
      alive: alive?(chain),
      ranges_done: length(counted),
      ranges_total: ranges_total(chain),
      current: Enum.find(runs, &(&1.outcome == "running")),
      rows_examined: sum(counted, & &1.rows_examined),
      rows_changed: sum(counted, & &1.rows_changed),
      rows_below_version: sum(counted, &(&1.rows_below_version || 0)),
      blocks_examined: sum(counted, & &1.blocks_examined),
      details: sum_details(counted),
      not_ok: Enum.count(runs, &(&1.outcome not in ["ok", "running"]))
    }
  end

  defp ranges_total(c), do: ceil((c.range_to - c.range_from + 1) / c.range_step)

  defp sum(runs, fun), do: runs |> Enum.map(fun) |> Enum.sum()

  # Counts add up across ranges; a version in `details` stays as it is.
  defp sum_details(runs) do
    Enum.reduce(runs, %{}, fn run, acc ->
      Map.merge(acc, run.details, fn
        key, a, b when is_number(a) and is_number(b) ->
          if String.ends_with?(key, "_version"), do: b, else: a + b

        _key, _a, b ->
          b
      end)
    end)
  end
end
