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

  ## Checkpoint and hand-off (https://github.com/afomi/bitblocks/issues/115)

  After each batch the job saves `checkpoint_height`, the highest height (tx
  id for `tx_size`) whose batch is committed, in the same UPDATE as the
  heartbeat, and the run's counts so far in the same transaction. A job that
  takes a range with a checkpoint inside it starts at the checkpoint plus
  one, whether it follows a hand-off, a crash or a Lifeline rescue; moving
  `next_from` on clears it. So the counts of the runs of a range, however it
  ended, add up to the range once.

  A block backfill's cursor is the last block of its batch, and
  `blocks.height` is unique, so that height is done whole. A batch also ends
  inside a dense block once its time is up (`Bitblocks.Derivations`: about
  20 s a batch, sized from the last one), for the backfills whose pages
  stand alone (`tx_steps`, `script_analysis`, `timelocks`, `bap`): its
  cursor `{:within, height, tx_id}` saves `checkpoint_height` with
  `checkpoint_tx_id`, and the next job resumes inside that block, after that
  tx (`resume_after_tx:`). `tallies` and `tx_types` sum or stamp a block
  whole, so they end their batches between blocks only. `token_recipients`
  pages by instance id, not height, so it has no checkpoint: it starts its
  range over, and rows already at the version drop out; an applied run saves
  its counts per batch and can hand off, a dry run (whose rows stay below the
  version, so a rerun counts them again) does neither.

  On a deploy, each node gets SIGTERM. `Bitblocks.Application.prep_stop/1`
  sets `Bitblocks.Shutdown` before the supervision tree stops; the flag is a
  `:persistent_term`, free to read after every batch, and up for the whole of
  Oban's 60 s `shutdown_grace_period` (`Bitblocks.Shutdown` says why there).
  The batch in flight reads it too (`interrupt?:`), and ends after the page
  it is on. At that boundary the job stops (the run reads `halted`), clears
  the heartbeat, stamps `handed_off_at` and returns `{:snooze, 5}`, so it is
  never left `executing` for Lifeline, and the other node (or the new one)
  takes the range within seconds, from the checkpoint. A job that starts on
  a stopping node snoozes the same way.

  ## The watchdog: a batch that won't stop in time

  A single page, statement or streamed block can still outlast the window.
  So the backfill runs in a runner process the job spawns and links, and
  the job process waits for it, checking every half second how long the
  node has been stopping (`Bitblocks.Shutdown.stopping_for_ms/0`). Once that
  passes `config :bitblocks, :backfill_watchdog_ms` (45 s, well inside the
  60 s grace period), the job stops the batch itself:

    1. It reads the bounded transaction the runner has open, if any (its
       backend pid and `xact_start`, noted by `Derivations.bounded/2` under
       `watched: true`), unlinks the runner and kills it (`:kill`, which
       can't be caught), then waits for it to be gone, so no write of its
       lands after the hand-off.
    2. The transaction rolls back. A COMMIT is only ever sent by the
       runner, which is dead, so nothing of the batch in flight commits.
       DBConnection's pool owns the connection, and on its holder's death
       it disconnects it rather than checking it back in; Postgres aborts a
       transaction whose client is gone. A statement still running on the
       server would only notice at its end, holding its row locks until
       then, so the job also cancels it (`pg_cancel_backend`), only while
       that backend is still in that same transaction: a connection already
       back in the pool has another `xact_start`, and is left alone.
    3. It hands off at the last committed checkpoint, as above: the run
       left `running` reads `halted`, the heartbeat is cleared, and the job
       returns `{:snooze, 5}`. Oban records the snooze as `scheduled` five
       seconds out, not an error, so no attempt is spent (Oban takes the
       attempt back with each snooze) and the row is never left
       `executing`. The other node's job claims the range with the same
       conditional UPDATE as ever, on a heartbeat now nil, so two copies
       never work one range; the dead runner can't beat it again.

  What the killed batch committed before its last checkpoint is kept and
  not redone; what it committed after (earlier pages of the same batch)
  stays applied, and the resume selects by version or missing rows, so it
  reads those rows again but writes nothing for them; its counts for them
  are lost, so a range stopped this way may count a few rows short.

  A node that dies outright (no SIGTERM, or past the grace period) takes the
  runner with it through the link; the heartbeat goes stale and the range
  passes on through Lifeline and the stale claim, from the checkpoint, as
  before.
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
  @backfill_opts ~w(force revisit_unknown pause_ms statement_timeout_ms block_batch tx_batch min_tx_batch batch_size id_window max_failures large_blocks batch_ms page_ms)a

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

  # How long a job handing off waits before a node takes the range again.
  @hand_off_snooze_s 5

  # How long after the node starts to stop the watchdog stops a batch still
  # running: well inside Oban's 60 s shutdown_grace_period (config/config.exs),
  # leaving time to wait for the beater (up to 5 s) and hand off.
  # `config :bitblocks, :backfill_watchdog_ms` overrides it.
  @watchdog_ms :timer.seconds(45)

  # How often the waiting job checks the watchdog.
  # `config :bitblocks, :backfill_watchdog_poll_ms` overrides it.
  @watchdog_poll_ms 500

  # Runs whose counts a status sums: all but one still running. A run's counts
  # cover the batches up to its chain's checkpoint, which the next run of the
  # range starts after. (A run abandoned before checkpoints holds zeros.)
  @counted_outcomes ~w(ok halted partial abandoned)

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
      stopping?() -> {:snooze, @hand_off_snooze_s}
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
    {start, after_tx} = resume_at(chain, from, to)

    if start > to do
      # The checkpoint already reached the end: a job stopped after the last batch.
      clear_heartbeat(chain.id)
      advance(chain, from, to)
    else
      every = Application.get_env(:bitblocks, :backfill_beat_every_ms, @beat_every_ms)

      result =
        with_heartbeat(chain.id, every, fn ->
          run_watched(fn -> run_backfill(chain, start, to, after_tx) end)
        end)

      case result do
        :watchdog ->
          watchdog_hand_off(chain)

        %{outcome: "halted"} = report ->
          hand_off(chain, report)

        %{outcome: "ok"} ->
          clear_heartbeat(chain.id)
          advance(chain, from, to)

        report ->
          clear_heartbeat(chain.id)
          retry_or_fail(chain, report.error, last_attempt?)
      end
    end
  end

  # Where a job takes the range up, as {height, after_tx_id}: inside the
  # checkpoint's block when the batch stopped inside it, after the checkpoint
  # when that block is done whole, else at the range's start.
  defp resume_at(%{checkpoint_height: h, checkpoint_tx_id: tx}, from, to)
       when is_integer(h) and h >= from and h <= to and is_integer(tx),
       do: {h, tx}

  defp resume_at(%{checkpoint_height: h}, from, to)
       when is_integer(h) and h >= from and h <= to,
       do: {h + 1, nil}

  defp resume_at(_chain, from, _to), do: {from, nil}

  @doc false
  # Runs `fun` (a range's backfill) in a runner process linked to this one,
  # and waits for its result, which it returns (an exception in it is raised
  # here, as if `fun` ran here). While it waits it checks the watchdog: once
  # the node has been stopping for `:backfill_watchdog_ms`, it kills the
  # runner, cancels the statement it left open, and returns `:watchdog`.
  # The moduledoc says why the batch's transaction rolls back.
  def run_watched(fun) do
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]
    metadata = Logger.metadata()

    runner =
      spawn_link(fn ->
        # The sandbox in tests, and log lines, follow the job.
        Process.put(:"$callers", callers)
        Logger.metadata(metadata)

        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        send(parent, {ref, result})
      end)

    case await_runner(runner, ref) do
      {:ok, result} -> result
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      :watchdog -> :watchdog
    end
  end

  defp await_runner(runner, ref) do
    receive do
      {^ref, result} -> result
    after
      watchdog_poll_ms() ->
        if watchdog_due?(),
          do: stop_runner(runner, ref),
          else: await_runner(runner, ref)
    end
  end

  # Kills the runner and waits until it is gone. A result it sent first wins:
  # the batch finished after all.
  defp stop_runner(runner, ref) do
    open = Derivations.open_transaction(runner)
    monitor = Process.monitor(runner)
    Process.unlink(runner)
    Process.exit(runner, :kill)

    receive do
      {:DOWN, ^monitor, :process, _, _} -> :ok
    end

    receive do
      {^ref, result} -> result
    after
      0 ->
        cancelled? = cancel_open(open)

        Logger.warning(
          "Backfill: shutdown watchdog stopped the batch in flight" <>
            if(cancelled?, do: "; its statement cancelled", else: "")
        )

        :watchdog
    end
  end

  # Cancelling is only to free the dead transaction's locks sooner; it never
  # decides whether the batch committed, so a failure here is only logged.
  defp cancel_open(open) do
    Derivations.cancel_transaction(open)
  rescue
    error ->
      Logger.warning("Backfill: statement not cancelled: " <> Exception.message(error))
      false
  end

  defp watchdog_due? do
    case Bitblocks.Shutdown.stopping_for_ms() do
      nil -> false
      ms -> ms >= Application.get_env(:bitblocks, :backfill_watchdog_ms, @watchdog_ms)
    end
  end

  defp watchdog_poll_ms,
    do: Application.get_env(:bitblocks, :backfill_watchdog_poll_ms, @watchdog_poll_ms)

  # The watchdog stopped the batch: the runner is dead, its transaction
  # rolled back, and the beater has stopped (with_heartbeat waits for it).
  # Hand off at the last committed checkpoint, as at a batch boundary.
  defp watchdog_hand_off(chain) do
    {1, [{checkpoint, tx}]} =
      Repo.update_all(
        from(c in BackfillChain,
          where: c.id == ^chain.id,
          select: {c.checkpoint_height, c.checkpoint_tx_id}
        ),
        set: [heartbeat_at: nil, handed_off_at: DateTime.utc_now()]
      )

    running = from(r in Run, where: r.chain_id == ^chain.id and r.outcome == "running")

    if checkpoint do
      Repo.update_all(where(running, [r], not is_nil(r.to_height)), set: [to_height: checkpoint])
    end

    # Its counts are those saved with its last checkpoint.
    Repo.update_all(running,
      set: [
        outcome: "halted",
        error: "stopped by the shutdown watchdog mid-batch; resumes from the checkpoint",
        finished_at: DateTime.utc_now(),
        updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      ]
    )

    Logger.info(
      "Backfill chain ##{chain.id}: node stopping, batch stopped by the watchdog; " <>
        "handed off at checkpoint #{describe_checkpoint(checkpoint, tx)}"
    )

    {:snooze, @hand_off_snooze_s}
  end

  defp describe_checkpoint(checkpoint, nil), do: inspect(checkpoint)
  defp describe_checkpoint(checkpoint, tx), do: "#{checkpoint} (inside, after tx id #{tx})"

  # The node is stopping and the run halted at a batch boundary, its
  # checkpoint and counts saved with that batch. The beater has stopped
  # (with_heartbeat waits for it), so no beat lands after this clear, and the
  # next job finds the range free at once.
  defp hand_off(chain, report) do
    {1, [{checkpoint, tx}]} =
      Repo.update_all(
        from(c in BackfillChain,
          where: c.id == ^chain.id,
          select: {c.checkpoint_height, c.checkpoint_tx_id}
        ),
        set: [heartbeat_at: nil, handed_off_at: DateTime.utc_now()]
      )

    # The run covered its start up to the checkpoint; the next starts after it.
    # (A tx_size run records no heights.)
    if report.run_id && checkpoint && report.to_height do
      Repo.update_all(from(r in Run, where: r.id == ^report.run_id), set: [to_height: checkpoint])
    end

    Logger.info(
      "Backfill chain ##{chain.id}: node stopping; handed off at checkpoint " <>
        describe_checkpoint(checkpoint, tx)
    )

    {:snooze, @hand_off_snooze_s}
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

  defp run_backfill(chain, from, to, after_tx) do
    resume = if after_tx, do: [resume_after_tx: after_tx], else: []
    inside = if after_tx, do: " (after tx id #{after_tx})", else: ""

    opts =
      for {key, value} <- chain.opts, atom = allowed(key), atom != nil do
        {atom, value}
      end ++
        resume ++
        [
          apply: chain.applied,
          chain_id: chain.id,
          command: "chain ##{chain.id} #{chain.derivation} #{from}..#{to}#{inside}",
          after_batch: &after_batch(chain, &1, &2),
          # The batch in flight ends at its next page once the node is stopping.
          interrupt?: &stopping?/0,
          # Its open transaction is noted, for the watchdog.
          watched: true
        ]

    backfill(chain.derivation, from, to, opts)
  end

  # After each committed batch: beat, save the checkpoint where it is exact
  # (with the run's counts, in one transaction), and stop here when the node
  # is stopping and the range can be handed on from this point.
  defp after_batch(chain, cursor, report) do
    checkpoint = checkpoint(chain.derivation, cursor)
    save_batch(chain, checkpoint, report)

    if stopping?() and hand_off?(chain, checkpoint),
      do: :halt,
      else: :cont
  end

  # The node is stopping (`Bitblocks.Shutdown`). `config :bitblocks,
  # :backfill_stopping?` (a 0-arity fun) stands in for it in tests.
  defp stopping? do
    case Application.get_env(:bitblocks, :backfill_stopping?) do
      nil -> Bitblocks.Shutdown.stopping?()
      fun -> fun.()
    end
  end

  # {:at, h}: every row at or below h in the range is done. The block
  # backfills page blocks keyset on (height, id), and `blocks.height` is
  # unique, so the last block's height is done whole. :none: the cursor isn't
  # a height (token_recipients pages by instance id).
  defp checkpoint("tx_size", id) when is_integer(id), do: {:at, id}
  defp checkpoint("token_recipients", _cursor), do: :none

  # Inside a dense block: done below it, and in it through that tx id.
  defp checkpoint(_derivation, {:within, height, tx_id})
       when is_integer(height) and is_integer(tx_id),
       do: {:within, height, tx_id}

  defp checkpoint(_derivation, {height, _id}) when is_integer(height), do: {:at, height}
  defp checkpoint(_derivation, {height, _id, _}) when is_integer(height), do: {:at, height}
  defp checkpoint(_derivation, _cursor), do: :none

  defp hand_off?(_chain, {:at, _}), do: true
  defp hand_off?(_chain, {:within, _, _}), do: true
  defp hand_off?(chain, :none), do: chain.applied

  defp save_batch(chain, checkpoint, report) do
    now = DateTime.utc_now()

    {set, counts?} =
      case checkpoint do
        {:at, height} ->
          {[heartbeat_at: now, checkpoint_height: height, checkpoint_tx_id: nil], true}

        {:within, height, tx_id} ->
          {[heartbeat_at: now, checkpoint_height: height, checkpoint_tx_id: tx_id], true}

        :none ->
          {[heartbeat_at: now], chain.applied}
      end

    Repo.transaction(
      fn ->
        Repo.update_all(from(c in BackfillChain, where: c.id == ^chain.id), set: set)
        if counts? and report.run_id, do: save_counts(report)
      end,
      timeout: @beat_timeout_ms
    )
  rescue
    # A checkpoint behind is safe: the next job redoes a batch. The beater
    # keeps the heartbeat fresh meanwhile.
    error ->
      Logger.warning(
        "Backfill chain ##{chain.id}: checkpoint not written, retrying next batch: " <>
          Exception.message(error)
      )
  end

  defp save_counts(report) do
    Repo.update_all(from(r in Run, where: r.id == ^report.run_id),
      set: [
        rows_examined: report.rows_examined,
        rows_changed: report.rows_changed,
        rows_below_version: report.rows_below_version,
        blocks_examined: report.blocks_examined,
        details: report.details
      ]
    )
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

    # Keyed on next_from, so only one copy of a job moves the chain on. The
    # checkpoint belonged to this range, so it goes with it.
    {moved, _} =
      Repo.update_all(
        from(c in BackfillChain, where: c.id == ^chain.id and c.next_from == ^from),
        set: [next_from: to + 1, checkpoint_height: nil, checkpoint_tx_id: nil]
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
    counted = Enum.filter(runs, &(&1.outcome in counted_outcomes(chain)))
    alive = alive?(chain)

    %{
      chain: chain,
      alive: alive,
      ranges_done: Enum.count(runs, &(&1.outcome == "ok")),
      checkpoint_height: chain.checkpoint_height,
      checkpoint_tx_id: chain.checkpoint_tx_id,
      handed_off_at: chain.handed_off_at,
      hand_offs: Enum.count(runs, &(&1.outcome == "halted")),
      ranges_total: ranges_total(chain),
      current: if(alive, do: Enum.find(runs, &(&1.outcome == "running"))),
      next_range: next_range(chain),
      rows_examined: sum(counted, & &1.rows_examined),
      rows_changed: sum(counted, & &1.rows_changed),
      rows_below_version: sum(counted, &(&1.rows_below_version || 0)),
      blocks_examined: sum(counted, & &1.blocks_examined),
      details: sum_details(counted),
      not_ok: Enum.count(runs, &(&1.outcome not in ["ok", "running", "halted"]))
    }
  end

  # A token_recipients dry run has no checkpoint and its rows stay below the
  # version, so a rerun counts the whole range again: only `ok` runs add up.
  defp counted_outcomes(%{derivation: "token_recipients", applied: false}), do: ["ok"]
  defp counted_outcomes(_chain), do: @counted_outcomes

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
