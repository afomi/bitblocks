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
  `rescue_after`. A process linked to the job beats the chain's heartbeat every
  minute while the range runs, however long one batch takes, so the rescued
  copy sees a live job and snoozes; when it wakes, `next_from` has moved on and
  it stops. (Beating only once per batch let a batch of dense blocks outlast
  the stale limit, and a rescued copy ran the same range beside the live one.)

  A dry run's counts live in its `derivation_runs` rows, and `status/1` sums
  them, so they survive a restart too.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.TxPipeline.{
    Backfill,
    BapBackfill,
    ScriptAnalysisBackfill,
    TimelocksBackfill,
    TokenRecipientsBackfill,
    TxStepsBackfill,
    TxTypesBackfill
  }

  alias Bitblocks.Chain.{Transaction, TxSizeBackfill}
  alias Bitblocks.Derivations
  alias Bitblocks.Derivations.{BackfillChain, Run}
  alias Bitblocks.Repo
  alias Bitblocks.TxStore.BlockObjectsBackfill
  alias Bitblocks.Workers.BackfillChainWorker

  @derivations ~w(script_analysis tx_steps tallies tx_types tx_size bap token_recipients timelocks block_objects)

  # What a job passes on to the backfill. Named here because opts come back
  # from JSON, and arbitrary strings must never become atoms.
  @backfill_opts ~w(force revisit_unknown pause_ms statement_timeout_ms block_batch tx_batch min_tx_batch batch_size id_window max_failures large_blocks)a

  @height_step 10_000
  @id_step 1_000_000

  # A beat older than this means the job died. Well above a batch's length,
  # and below Lifeline's 30 minutes, so a rescued job finds a dead one stale.
  @heartbeat_stale_ms :timer.minutes(15)

  # How often the beater beats while a range runs: far below the stale limit.
  # `config :bitblocks, :backfill_beat_every_ms` overrides it (tests).
  @beat_every_ms :timer.minutes(1)

  # A beat that can't write within this gives up until the next one; below the
  # 5 s the job waits for its beater to stop, so no beat lands after the clear.
  @beat_timeout_ms 4_000

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
      claim(chain.id) -> work(chain, from, last_attempt?)
      true -> {:snooze, 120}
    end
  end

  # Takes the range only when no live job holds it: one conditional UPDATE, so
  # two copies that both find the heartbeat stale can't both run (a read, then
  # a beat, left that window open).
  defp claim(id) do
    now = DateTime.utc_now()
    stale_before = DateTime.add(now, -@heartbeat_stale_ms, :millisecond)

    {n, _} =
      Repo.update_all(
        from(c in BackfillChain,
          where: c.id == ^id and (is_nil(c.heartbeat_at) or c.heartbeat_at < ^stale_before)
        ),
        set: [heartbeat_at: now]
      )

    n == 1
  end

  defp alive?(%{heartbeat_at: nil}), do: false

  defp alive?(%{heartbeat_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at, :millisecond) < @heartbeat_stale_ms

  defp work(chain, from, last_attempt?) do
    close_dead_runs(chain)

    to = min(from + chain.range_step - 1, chain.range_to)
    every = Application.get_env(:bitblocks, :backfill_beat_every_ms, @beat_every_ms)
    report = with_heartbeat(chain.id, every, fn -> run_backfill(chain, from, to) end)
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
  defp backfill("bap", from, to, opts), do: BapBackfill.run(from, to, opts)
  defp backfill("timelocks", from, to, opts), do: TimelocksBackfill.run(from, to, opts)
  defp backfill("block_objects", from, to, opts), do: BlockObjectsBackfill.run(from, to, opts)

  defp backfill("token_recipients", from, to, opts),
    do: TokenRecipientsBackfill.run(from, to, opts)

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

  @doc false
  # Runs `fun` while a linked process beats the chain's heartbeat every
  # `every_ms`, from before `fun` starts until it returns or raises. Linked, so
  # a job that dies takes its beater with it and the heartbeat goes stale. A
  # beat that fails is logged and the next one retries, so a database blip
  # never takes the live range down through the link.
  def with_heartbeat(id, every_ms, fun, beat \\ &beat/1) do
    beat.(id)
    {:ok, beater} = Task.start_link(fn -> beat_loop(id, every_ms, beat) end)

    try do
      fun.()
    after
      ref = Process.monitor(beater)
      send(beater, :stop)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        5_000 ->
          Process.unlink(beater)
          Process.exit(beater, :kill)
      end
    end
  end

  defp beat_loop(id, every_ms, beat) do
    receive do
      :stop -> :ok
    after
      every_ms ->
        safe_beat(beat, id)
        beat_loop(id, every_ms, beat)
    end
  end

  defp safe_beat(beat, id) do
    beat.(id)
  rescue
    error ->
      Logger.warning(
        "Backfill chain ##{id}: heartbeat not written, retrying next beat: " <>
          Exception.message(error)
      )
  end

  defp beat(id) do
    Repo.update_all(
      from(c in BackfillChain, where: c.id == ^id),
      [set: [heartbeat_at: DateTime.utc_now()]],
      timeout: @beat_timeout_ms
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

  # `current` is the run a live job is working on. A run left `running` with
  # no live heartbeat belongs to a job that died (a restart, say, with the
  # chain paused before the rerun): nothing works on it, so it is not current.
  defp summarize(chain) do
    runs = Repo.all(from(r in Run, where: r.chain_id == ^chain.id, order_by: [asc: r.id]))
    counted = Enum.filter(runs, &(&1.outcome == "ok"))
    alive = alive?(chain)

    %{
      chain: chain,
      alive: alive,
      ranges_done: length(counted),
      ranges_total: ranges_total(chain),
      current: if(alive, do: Enum.find(runs, &(&1.outcome == "running"))),
      next_range: next_range(chain),
      rows_examined: sum(counted, & &1.rows_examined),
      rows_changed: sum(counted, & &1.rows_changed),
      rows_below_version: sum(counted, &(&1.rows_below_version || 0)),
      blocks_examined: sum(counted, & &1.blocks_examined),
      details: sum_details(counted),
      not_ok: Enum.count(runs, &(&1.outcome not in ["ok", "running"]))
    }
  end

  defp ranges_total(c), do: ceil((c.range_to - c.range_from + 1) / c.range_step)

  # The range the chain takes next, or nil once it has passed its end.
  defp next_range(%{next_from: from, range_to: to}) when from > to, do: nil
  defp next_range(c), do: {c.next_from, min(c.next_from + c.range_step - 1, c.range_to)}

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
