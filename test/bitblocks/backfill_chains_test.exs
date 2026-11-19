defmodule Bitblocks.BackfillChainsTest do
  # A backfill as a chain of Oban jobs (docs/DERIVED_DATA.md): one range per
  # job, carried across a restart, with nothing left `running`.
  use Bitblocks.DataCase, async: false
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.BackfillChains
  alias Bitblocks.Chain.{RawBlock, Transaction, TxIngest}
  alias Bitblocks.Derivations.{BackfillChain, Run}
  alias Bitblocks.Release
  alias Bitblocks.Workers.BackfillChainWorker

  defp store_tx(height) do
    {txid, hex} = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
    json = RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))
    :ok = TxIngest.store(json, block_fixture(%{height: height}))
    Repo.get_by!(Transaction, txid: txid)
  end

  defp unfill(tx) do
    Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
      set: [size_bytes: nil, raw_in_db: nil]
    )
  end

  defp size_chain(tx, opts) do
    {:ok, chain} =
      BackfillChains.start("tx_size", tx.id, tx.id + 2, Keyword.put_new(opts, :step, 2))

    chain
  end

  defp perform(chain, from, attempt \\ 1) do
    perform_job(BackfillChainWorker, %{"chain_id" => chain.id, "from" => from}, attempt: attempt)
  end

  defp reload(chain), do: Repo.get!(BackfillChain, chain.id)

  defp minutes_ago(m), do: DateTime.add(DateTime.utc_now(), -m * 60, :second)

  defp set_heartbeat(chain, at) do
    chain |> Ecto.Changeset.change(heartbeat_at: at) |> Repo.update!()
  end

  setup do
    tx = store_tx(90)
    unfill(tx)
    %{tx: tx}
  end

  test "walks the ranges job by job, then finishes", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    assert_enqueued(worker: BackfillChainWorker, args: %{chain_id: chain.id, from: tx.id})

    assert :ok = perform(chain, tx.id)
    assert reload(chain).next_from == tx.id + 2
    assert reload(chain).heartbeat_at == nil
    assert_enqueued(worker: BackfillChainWorker, args: %{chain_id: chain.id, from: tx.id + 2})
    assert Repo.get!(Transaction, tx.id).raw_in_db == true

    assert :ok = perform(chain, tx.id + 2)
    assert %{status: "done", finished_at: %DateTime{}} = reload(chain)

    assert [%Run{chain_id: id, outcome: "ok"}, %Run{outcome: "ok"}] =
             Repo.all(from(r in Run, order_by: r.id))

    assert id == chain.id
  end

  test "a dry run writes nothing and its counts stay readable", %{tx: tx} do
    chain = size_chain(tx, [])

    :ok = perform(chain, tx.id)
    :ok = perform(chain, tx.id + 2)

    assert Repo.get!(Transaction, tx.id).raw_in_db == nil

    assert %{
             rows_changed: 1,
             rows_below_version: 1,
             ranges_done: 2,
             ranges_total: 2,
             details: %{"no_raw" => 0}
           } = BackfillChains.status(chain.id)
  end

  test "a job back after a restart closes the dead run and reruns the range", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    set_heartbeat(chain, minutes_ago(30))

    dead =
      Repo.insert!(%Run{
        derivation: "tx_size",
        version: 1,
        chain_id: chain.id,
        outcome: "running",
        applied: true,
        started_at: minutes_ago(30)
      })

    assert :ok = perform(chain, tx.id, 2)

    assert %Run{outcome: "abandoned", finished_at: %DateTime{}} = Repo.get!(Run, dead.id)
    assert Repo.get!(Transaction, tx.id).raw_in_db == true
    assert Repo.aggregate(from(r in Run, where: r.outcome == "running"), :count) == 0
  end

  test "a rescued copy of a live job waits, and stops once the range moved on", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    set_heartbeat(chain, DateTime.utc_now())

    assert {:snooze, _} = perform(chain, tx.id, 2)
    assert Repo.get!(Transaction, tx.id).raw_in_db == nil

    chain |> Ecto.Changeset.change(next_from: tx.id + 2, heartbeat_at: nil) |> Repo.update!()

    assert {:cancel, :superseded} = perform(chain, tx.id, 2)
    assert Repo.get!(Transaction, tx.id).raw_in_db == nil
  end

  test "a paused chain runs nothing more until it is resumed", %{tx: tx} do
    chain = size_chain(tx, apply: true)

    Repo.delete_all(Oban.Job)
    {:ok, _} = BackfillChains.pause(chain.id)

    assert {:cancel, {:chain, "paused"}} = perform(chain, tx.id)
    refute_enqueued(worker: BackfillChainWorker)

    {:ok, _} = BackfillChains.resume(chain.id)
    assert_enqueued(worker: BackfillChainWorker, args: %{chain_id: chain.id, from: tx.id})
    assert reload(chain).status == "running"
  end

  defp dead_run(chain, command) do
    Repo.insert!(%Run{
      derivation: chain.derivation,
      version: 1,
      chain_id: chain.id,
      outcome: "running",
      applied: chain.applied,
      command: command,
      started_at: minutes_ago(30)
    })
  end

  defp status_output(chain), do: capture_io(fn -> Release.backfill_status(chain.id) end)

  # https://github.com/afomi/bitblocks/issues/82
  test "a paused chain's status says paused and names its next range", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    dead_run(chain, "chain ##{chain.id} tx_size #{tx.id}..#{tx.id + 1}")
    {:ok, _} = BackfillChains.pause(chain.id)

    assert %{current: nil, next_range: {from, to}} = BackfillChains.status(chain.id)
    assert {from, to} == {tx.id, tx.id + 1}

    output = status_output(chain)
    assert output =~ "paused; next #{tx.id}..#{tx.id + 1}"
    refute output =~ "working"
  end

  test "a chain paused mid-range says it is finishing that range", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    command = "chain ##{chain.id} tx_size #{tx.id}..#{tx.id + 1}"
    dead_run(chain, command)
    set_heartbeat(chain, DateTime.utc_now())
    {:ok, _} = BackfillChains.pause(chain.id)

    output = status_output(chain)
    assert output =~ "paused, finishing #{command}"
    refute output =~ "working"
  end

  test "a running chain with a live job reads working", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    command = "chain ##{chain.id} tx_size #{tx.id}..#{tx.id + 1}"
    dead_run(chain, command)
    set_heartbeat(chain, DateTime.utc_now())

    assert status_output(chain) =~ "working #{command}"
  end

  test "cancelled and done chains never read working", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    dead_run(chain, "chain ##{chain.id} tx_size #{tx.id}..#{tx.id + 1}")
    {:ok, _} = BackfillChains.cancel(chain.id)

    output = status_output(chain)
    assert output =~ "cancelled; next #{tx.id}..#{tx.id + 1}"
    refute output =~ "working"

    Repo.delete_all(Run)
    other = size_chain(tx, apply: true)
    :ok = perform(other, tx.id)
    :ok = perform(other, tx.id + 2)

    output = status_output(other)
    assert output =~ "2 of 2 range(s) finished, done"
    refute output =~ "working"
  end

  test "a cancel ends the chain", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    {:ok, _} = BackfillChains.cancel(chain.id)

    assert {:cancel, {:chain, "cancelled"}} = perform(chain, tx.id)
    assert {:error, _} = BackfillChains.resume(chain.id)
  end

  test "a second chain for the same derivation is refused until the first ends", %{tx: tx} do
    chain = size_chain(tx, apply: true)

    assert {:error, {:already_active, id}} = BackfillChains.start("tx_size", 1, 10, apply: true)
    assert id == chain.id

    {:ok, _} = BackfillChains.cancel(chain.id)
    assert {:ok, _} = BackfillChains.start("tx_size", 1, 10, apply: true)
  end

  test "a range out of attempts fails the chain, and it can be resumed", %{tx: tx} do
    chain = size_chain(tx, apply: true, statement_timeout_ms: -1)

    assert {:error, _} = perform(chain, tx.id, 20)
    assert %{status: "failed", error: error} = reload(chain)
    assert is_binary(error)

    assert {:ok, %{status: "running", error: nil}} = BackfillChains.resume(chain.id)
  end

  describe "the heartbeat while a range runs" do
    # A batch of dense blocks can outlast the stale limit; beating only per
    # batch let a rescued copy run the same range beside the live job.
    test "beats while the range is still in one long batch, and stops after", %{tx: tx} do
      chain = size_chain(tx, apply: true)
      set_heartbeat(chain, minutes_ago(60))

      result =
        BackfillChains.with_heartbeat(chain.id, 20, fn ->
          Process.sleep(30)
          first = reload(chain).heartbeat_at
          Process.sleep(200)
          {first, reload(chain).heartbeat_at}
        end)

      {first, later} = result
      assert DateTime.diff(DateTime.utc_now(), first, :second) < 5
      assert DateTime.compare(later, first) == :gt

      settled = reload(chain).heartbeat_at
      Process.sleep(60)
      assert reload(chain).heartbeat_at == settled
    end

    test "a job's range is beaten while it runs, not only between batches", %{tx: tx} do
      # One batch here, slowed by pause_ms: only a beater writes during it.
      Application.put_env(:bitblocks, :backfill_beat_every_ms, 10)
      on_exit(fn -> Application.delete_env(:bitblocks, :backfill_beat_every_ms) end)
      chain = size_chain(tx, apply: true, pause_ms: 300)

      watcher =
        Task.async(fn ->
          for _ <- 1..40, reduce: MapSet.new() do
            seen ->
              Process.sleep(10)
              MapSet.put(seen, reload(chain).heartbeat_at)
          end
        end)

      assert :ok = perform(chain, tx.id)
      beats = watcher |> Task.await() |> MapSet.delete(nil)
      assert MapSet.size(beats) >= 5
    end

    test "of two copies finding a stale heartbeat, only one takes the range", %{tx: tx} do
      chain = size_chain(tx, apply: true)
      set_heartbeat(chain, minutes_ago(60))

      BackfillChains.with_heartbeat(chain.id, 60_000, fn ->
        # This job has claimed the range; a second copy now finds it held.
        assert {:snooze, _} = perform(chain, tx.id)
      end)
    end

    test "a heartbeat that fails to write doesn't stop the range", %{tx: tx} do
      chain = size_chain(tx, apply: true)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      # The first beat (before the range) writes; every later one raises, as a
      # pool timeout or a failover would.
      flaky = fn id ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            Repo.update_all(from(c in BackfillChain, where: c.id == ^id),
              set: [heartbeat_at: DateTime.utc_now()]
            )

          _ ->
            raise DBConnection.ConnectionError, "connection not available"
        end
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :done =
                   BackfillChains.with_heartbeat(
                     chain.id,
                     10,
                     fn ->
                       Process.sleep(60)
                       :done
                     end,
                     flaky
                   )
        end)

      assert Agent.get(calls, & &1) >= 3
      assert log =~ "heartbeat not written"
    end

    test "a range that raises stops its beater too", %{tx: tx} do
      chain = size_chain(tx, apply: true)

      assert_raise RuntimeError, fn ->
        BackfillChains.with_heartbeat(chain.id, 20, fn ->
          raise "range failed"
        end)
      end

      settled = reload(chain).heartbeat_at
      Process.sleep(60)
      assert reload(chain).heartbeat_at == settled
    end

    test "a rescued copy finds the long-running job alive and snoozes", %{tx: tx} do
      chain = size_chain(tx, apply: true)
      set_heartbeat(chain, minutes_ago(60))

      BackfillChains.with_heartbeat(chain.id, 20, fn ->
        Process.sleep(40)
        assert {:snooze, _} = perform(chain, tx.id)
      end)
    end
  end

  # https://github.com/afomi/bitblocks/issues/115
  describe "checkpoint and hand-off" do
    setup %{tx: first} do
      txs = [first | Enum.map([91, 92], fn h -> h |> store_tx() |> tap(&unfill/1) end)]
      on_exit(fn -> Bitblocks.Shutdown.reset() end)
      %{txs: txs}
    end

    # One chain range over the three txs, one id per batch.
    defp three_chain([first, _, last], opts) do
      {:ok, chain} =
        BackfillChains.start(
          "tx_size",
          first.id,
          last.id,
          Keyword.merge([step: 10, id_window: 1], opts)
        )

      chain
    end

    defp filled?(tx), do: Repo.get!(Transaction, tx.id).raw_in_db == true

    # The chain's `stopping?` answers from this list, one answer per check
    # (run_range's first, then one per batch), then the last answer on.
    defp stop_after(answers) do
      {:ok, agent} = Agent.start_link(fn -> answers end)

      Application.put_env(:bitblocks, :backfill_stopping?, fn ->
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)
      end)

      on_exit(fn -> Application.delete_env(:bitblocks, :backfill_stopping?) end)
    end

    defp chain_runs(chain),
      do: Repo.all(from(r in Run, where: r.chain_id == ^chain.id, order_by: r.id))

    test "each batch saves its checkpoint and the run's counts so far", %{txs: txs} do
      [first, second, _] = txs
      chain = three_chain(txs, apply: true, pause_ms: 150)

      watcher =
        Task.async(fn ->
          for _ <- 1..80, reduce: MapSet.new() do
            seen ->
              Process.sleep(5)
              c = reload(chain)

              changed =
                Repo.one(from(r in Run, where: r.chain_id == ^chain.id, select: r.rows_changed))

              MapSet.put(seen, {c.checkpoint_height, changed})
          end
        end)

      assert :ok = perform(chain, first.id)
      seen = Task.await(watcher)

      # The checkpoint and the counts move together, batch by batch.
      assert {first.id, 1} in seen
      assert {second.id, 2} in seen
      # Moving next_from on clears it.
      assert %{checkpoint_height: nil, next_from: next} = reload(chain)
      assert next == List.last(txs).id + 1
    end

    test "a range with a checkpoint in it starts at the checkpoint plus one", %{txs: txs} do
      [first, second, third] = txs
      chain = three_chain(txs, apply: true)
      chain |> Ecto.Changeset.change(checkpoint_height: first.id) |> Repo.update!()

      assert :ok = perform(chain, first.id)

      refute filled?(first)
      assert filled?(second) and filled?(third)
      assert [%Run{outcome: "ok", command: command}] = chain_runs(chain)
      assert command =~ "#{second.id}..#{third.id}"
      assert %{status: "done", checkpoint_height: nil} = reload(chain)
    end

    test "a checkpoint past the range's last batch moves the chain on", %{txs: txs} do
      [first, _, third] = txs
      chain = three_chain(txs, apply: true)
      chain |> Ecto.Changeset.change(checkpoint_height: third.id) |> Repo.update!()

      assert :ok = perform(chain, first.id)
      refute filled?(first)
      assert chain_runs(chain) == []
      assert %{status: "done", checkpoint_height: nil, heartbeat_at: nil} = reload(chain)
    end

    test "a node stopping mid-range hands off at the next batch boundary", %{txs: txs} do
      [first, second, third] = txs
      chain = three_chain(txs, apply: true, pause_ms: 300)

      # The real flag, as prep_stop sets it, once the first batch is saved.
      Task.start(fn ->
        Enum.find(1..200, fn _ ->
          Process.sleep(5)
          reload(chain).checkpoint_height != nil
        end)

        Bitblocks.Shutdown.begin()
      end)

      assert {:snooze, 5} = perform(chain, first.id)

      assert %{heartbeat_at: nil, checkpoint_height: cp, handed_off_at: %DateTime{}} =
               reload(chain)

      assert cp == second.id
      assert filled?(first) and filled?(second)
      refute filled?(third)
      assert [%Run{outcome: "halted", rows_changed: 2}] = chain_runs(chain)
      assert Repo.aggregate(from(r in Run, where: r.outcome == "running"), :count) == 0

      # A job that starts while the node is stopping snoozes without the range.
      assert {:snooze, 5} = perform(chain, first.id)
      assert reload(chain).heartbeat_at == nil

      output = status_output(chain)
      assert output =~ "checkpoint #{second.id}"
      assert output =~ "last handed off"

      # The other node takes it at once, from the checkpoint.
      Bitblocks.Shutdown.reset()
      assert :ok = perform(chain, first.id)
      assert filled?(third)
      assert [%Run{outcome: "halted"}, %Run{outcome: "ok", command: command}] = chain_runs(chain)
      assert command =~ "#{third.id}..#{third.id}"
      assert %{status: "done", checkpoint_height: nil} = reload(chain)
    end

    test "prep_stop marks the node as stopping" do
      refute Bitblocks.Shutdown.stopping?()
      assert :state = Bitblocks.Application.prep_stop(:state)
      assert Bitblocks.Shutdown.stopping?()
    end

    test "a dry run's counts add up once across a hand-off", %{txs: txs} do
      [first, _, _] = txs
      chain = three_chain(txs, [])

      # Not at the start, stopping after the first batch.
      stop_after([false, true])
      assert {:snooze, 5} = perform(chain, first.id)
      assert %{checkpoint_height: cp} = reload(chain)
      assert cp == first.id

      stop_after([false])
      assert :ok = perform(chain, first.id)

      assert [%Run{outcome: "halted", rows_changed: 1}, %Run{outcome: "ok", rows_changed: 2}] =
               chain_runs(chain)

      assert %{
               rows_changed: 3,
               rows_examined: 3,
               rows_below_version: 3,
               ranges_done: 1,
               hand_offs: 1,
               not_ok: 0
             } = BackfillChains.status(chain.id)

      refute Enum.any?(txs, &filled?/1)
    end

    test "a crash with no hand-off: one copy claims the stale range, from the checkpoint",
         %{txs: txs} do
      [first, second, third] = txs
      chain = three_chain(txs, [])

      # A job died after its first batch: its checkpoint and counts saved with
      # that batch, its heartbeat gone stale, its run left running.
      chain
      |> Ecto.Changeset.change(checkpoint_height: first.id, heartbeat_at: minutes_ago(30))
      |> Repo.update!()

      dead = dead_run(chain, "chain ##{chain.id} tx_size #{first.id}..#{third.id}")

      dead
      |> Ecto.Changeset.change(rows_examined: 1, rows_changed: 1, rows_below_version: 1)
      |> Repo.update!()

      # Of two copies, the one that claims the range works it; the other waits.
      BackfillChains.with_heartbeat(chain.id, 60_000, fn ->
        assert {:snooze, 120} = perform(chain, first.id, 2)
      end)

      set_heartbeat(chain, minutes_ago(30))
      assert :ok = perform(chain, first.id, 2)

      assert [%Run{outcome: "abandoned"}, %Run{outcome: "ok", command: command}] =
               chain_runs(chain)

      assert command =~ "#{second.id}..#{third.id}"

      assert %{rows_changed: 3, rows_below_version: 3, not_ok: 1} =
               BackfillChains.status(chain.id)
    end
  end

  test "Release starts a chain and reads it back", %{tx: tx} do
    output =
      capture_io(fn ->
        Release.start_tx_sizes_backfill()
        [chain] = BackfillChains.list()
        assert chain.range_to == tx.id
        perform(chain, chain.range_from)
        Release.backfill_status(chain.id)
        Release.backfill_status()
      end)

    assert output =~ "STARTED"
    assert output =~ "DRY RUN"
    assert output =~ "1 row(s) to change"
  end
end
