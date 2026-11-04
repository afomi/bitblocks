defmodule Bitblocks.SyncTest do
  # Changes :sync_workers, :tx_fetch_run_ms and the run limits, and installs
  # global RPC stubs. One block per job here (:sync_run_max_blocks 1), so these
  # tests pin the per-block guarantees; "small-block runs" below turns runs on.
  use Bitblocks.DataCase, async: false
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.ChainFixtures
  import Swoosh.TestAssertions

  alias Bitblocks.{Chain, Sync}
  alias Bitblocks.Sync.Coordinator
  alias Bitblocks.Workers.{FetchTransactionsWorker, SyncHeadersWorker, SyncWorker}
  alias BitblocksWeb.RpcStub

  setup do
    RpcStub.setup()
    RpcStub.clear()
    Application.put_env(:bitblocks, :sync_run_max_blocks, 1)

    on_exit(fn ->
      Application.delete_env(:bitblocks, :sync_workers)
      Application.delete_env(:bitblocks, :tx_fetch_run_ms)
      Application.delete_env(:bitblocks, :sync_run_max_blocks)
    end)

    :ok
  end

  # A body and the txid it hashes to (TxIngest checks every body).
  defp raw(label), do: Base.encode16(label, case: :lower)

  defp txid(label) do
    :crypto.hash(:sha256, :crypto.hash(:sha256, label))
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> :binary.list_to_bin()
    |> Base.encode16(case: :lower)
  end

  defp labels(prefix, n), do: for(i <- 1..n, do: "#{prefix}-#{i}")

  # A block whose txids are stored on the row. merkleroot: nil skips the merkle
  # gate; the completeness gate still applies.
  defp block_at(height, state, labels \\ nil) do
    txids = Enum.map(labels || ["tx-#{height}"], &txid/1)

    block_fixture(%{
      height: height,
      hash: "block_#{height}",
      merkleroot: nil,
      num_tx: length(txids),
      tx: txids,
      sync_state: state
    })
  end

  defp stub_bodies(labels) do
    RpcStub.stub_batch_getrawtransaction(
      Map.new(
        labels,
        &{txid(&1), %{"txid" => txid(&1), "hex" => raw(&1), "vin" => [], "vout" => []}}
      )
    )
  end

  defp run(block) do
    FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})
  end

  defp dispatched_hashes do
    all_enqueued(worker: FetchTransactionsWorker)
    |> Enum.map(& &1.args["block_hash"])
    |> Enum.sort()
  end

  describe "complete_through" do
    test "is -1 with no blocks, and the tip when every block is completed" do
      assert Sync.complete_through() == -1

      for h <- 0..3, do: block_at(h, "completed")

      assert Sync.status() == %{tip: 3, complete_through: 3, target: nil}
    end

    test "stops below the lowest incomplete block" do
      for h <- 0..1, do: block_at(h, "completed")
      block_at(2, "failed")
      block_at(3, "completed")

      assert Sync.status() == %{tip: 3, complete_through: 1, target: 2}
    end

    test "stops below a missing header" do
      block_at(0, "completed")
      block_at(2, "completed")

      assert Sync.complete_through() == 0
    end

    test "moves only when the lowest incomplete block completes, even if higher ones finish first" do
      for h <- 0..1, do: block_at(h, "completed")
      b2 = block_at(2, "header_only")
      b3 = block_at(3, "header_only")
      stub_bodies(["tx-2", "tx-3"])

      assert :ok = run(b3)
      assert Chain.get_block!(3).sync_state == "completed"
      assert Sync.complete_through() == 1

      assert :ok = run(b2)
      assert Sync.complete_through() == 3
    end

    test "a reorg below it pulls it back" do
      for h <- 0..4, do: block_at(h, "completed")
      assert Sync.complete_through() == 4

      # Tip sync resolves a reorg by deleting our blocks above the fork point;
      # the node's replacement is stored as a header, which is incomplete.
      SyncHeadersWorker.delete_orphans(1, 4)
      assert Sync.complete_through() == 1

      block_at(2, "header_only")
      assert Sync.complete_through() == 1
    end
  end

  describe "small-block runs" do
    setup do
      Application.put_env(:bitblocks, :sync_run_max_blocks, 4)
      Application.put_env(:bitblocks, :sync_workers, 2)
      :ok
    end

    defp runs do
      all_enqueued(worker: FetchTransactionsWorker)
      |> Enum.map(&(&1.args["run"] || [&1.args["block_hash"]]))
      |> Enum.sort()
    end

    test "plan_runs groups small blocks up to the block and tx limits; a large block goes alone" do
      limits = %{max_blocks: 3, max_txs: 10, small_txs: 5}
      c = fn h, n -> %{height: h, hash: "h#{h}", num_tx: n} end

      assert Sync.plan_runs(for(h <- 1..7, do: c.(h, 1)), 2, limits) ==
               [[c.(1, 1), c.(2, 1), c.(3, 1)], [c.(4, 1), c.(5, 1), c.(6, 1)]]

      # The tx budget ends a run; a large block stops it and goes alone.
      assert Sync.plan_runs([c.(1, 5), c.(2, 5), c.(3, 5), c.(4, 1)], 3, limits) ==
               [[c.(1, 5), c.(2, 5)], [c.(3, 5), c.(4, 1)]]

      assert Sync.plan_runs([c.(1, 1), c.(2, 50), c.(3, 1)], 3, limits) ==
               [[c.(1, 1)], [c.(2, 50)], [c.(3, 1)]]

      # Unknown tx count: alone, never in a run.
      assert Sync.plan_runs([%{height: 1, hash: "h1", num_tx: nil}], 1, limits) ==
               [[%{height: 1, hash: "h1", num_tx: nil}]]
    end

    test "dispatch gives each slot a run of the lowest blocks, in order, and never one block twice" do
      for h <- 0..9, do: block_at(h, "header_only")

      assert Sync.dispatch() == 2

      assert runs() == [
               ["block_0", "block_1", "block_2", "block_3"],
               ["block_4", "block_5", "block_6", "block_7"]
             ]

      # Every member is held: nothing more is queued while the runs live.
      assert Sync.dispatch() == 0
      assert Enum.flat_map(Sync.live_jobs(), & &1.held) |> length() == 8
    end

    test "a run is reported at the block it is on now" do
      for h <- 0..3, do: block_at(h, "header_only")
      Sync.dispatch()

      Chain.get_block!("block_0")
      |> Ecto.Changeset.change(sync_state: "completed")
      |> Repo.update!()

      [job] = Sync.live_jobs()
      assert {job.hash, job.height} == {"block_1", 1}
    end

    test "the worker walks its run in height order and completes every block" do
      labels = for h <- 0..3, do: "tx-#{h}"
      stub_bodies(labels)
      for h <- 0..3, do: block_at(h, "header_only")

      run = Enum.map(0..3, &"block_#{&1}")

      assert FetchTransactionsWorker.perform(%Oban.Job{
               args: %{"block_hash" => "block_0", "run" => run},
               meta: %{}
             }) == :ok

      assert Sync.complete_through() == 3
    end

    test "past its time budget a run snoozes after the block it is on, and resumes there" do
      Application.put_env(:bitblocks, :tx_fetch_run_ms, 0)
      stub_bodies(for h <- 0..2, do: "tx-#{h}")
      for h <- 0..2, do: block_at(h, "header_only")

      job = %Oban.Job{
        args: %{"block_hash" => "block_0", "run" => ["block_0", "block_1", "block_2"]},
        meta: %{}
      }

      # Each pass makes progress: one block, then a snooze.
      assert FetchTransactionsWorker.perform(job) == {:snooze, 1}
      assert Sync.complete_through() == 0
      assert FetchTransactionsWorker.perform(job) == {:snooze, 1}
      assert FetchTransactionsWorker.perform(job) == :ok
      assert Sync.complete_through() == 2
    end
  end

  describe "dispatch" do
    test "queues the lowest incomplete blocks in ascending order from genesis, up to :sync_workers" do
      Application.put_env(:bitblocks, :sync_workers, 2)

      block_at(0, "completed")
      for h <- 1..4, do: block_at(h, "header_only")

      Sync.dispatch()

      assert dispatched_hashes() == ["block_1", "block_2"]
    end

    test "never queues two jobs for the same block" do
      Application.put_env(:bitblocks, :sync_workers, 2)
      for h <- 0..2, do: block_at(h, "header_only")

      Sync.dispatch()
      Sync.dispatch()
      {:ok, again} = Oban.insert(FetchTransactionsWorker.new(%{block_hash: "block_0"}))

      assert again.conflict?
      assert dispatched_hashes() == ["block_0", "block_1"]
    end

    test "a failed block is never skipped: it stays first in line" do
      Application.put_env(:bitblocks, :sync_workers, 1)
      block_at(0, "completed")
      block_at(1, "failed")
      block_at(2, "header_only")

      Sync.dispatch()

      assert dispatched_hashes() == ["block_1"]
    end
  end

  describe "a block's transactions" do
    test "are fetched sequentially, chunk by chunk in list order" do
      labels = labels("seq", 250)
      txids = Enum.map(labels, &txid/1)
      block = block_at(0, "header_only", labels)
      stub_bodies(labels)

      assert :ok = run(block)

      calls = RpcStub.calls(:batch_getrawtransaction)
      assert Enum.map(calls, fn [chunk, 1] -> length(chunk) end) == [100, 100, 50]
      assert Enum.flat_map(calls, fn [chunk, 1] -> chunk end) == txids
      assert Chain.get_block!(0).sync_state == "completed"
    end

    test "a large block is fetched across several bounded runs of the same job, and completes" do
      # A zero budget means one chunk per run.
      Application.put_env(:bitblocks, :tx_fetch_run_ms, 0)
      labels = labels("big", 250)
      block = block_at(0, "header_only", labels)
      stub_bodies(labels)

      {:ok, job} = Oban.insert(FetchTransactionsWorker.new(%{block_hash: block.hash}))

      results =
        for _ <- 1..3 do
          job = Repo.reload!(job)
          FetchTransactionsWorker.perform(job)
        end

      assert [{:snooze, _}, {:snooze, _}, :ok] = results
      assert Chain.get_block!(0).sync_state == "completed"
      # Each run resumed where the last stopped: every chunk fetched once.
      assert length(RpcStub.calls(:batch_getrawtransaction)) == 3
    end

    test "a failing block backs off exponentially and keeps its place" do
      for h <- 0..1, do: block_at(h, "completed")
      b2 = block_at(2, "header_only")
      b3 = block_at(3, "header_only")
      stub_bodies(["tx-3"])

      assert {:snooze, 60} = run(b2)
      assert {:snooze, 120} = run(b2)
      assert {:snooze, 240} = run(b2)

      failed = Chain.get_block!(2)
      assert failed.sync_state == "failed"
      assert failed.tx_sync_attempts == 3

      # Another worker carries on above it, but the cursor waits for block 2.
      assert :ok = run(b3)
      assert Sync.complete_through() == 1

      stub_bodies(["tx-2"])
      assert :ok = run(b2)
      assert Chain.get_block!(2).tx_sync_attempts == 0
      assert Sync.complete_through() == 3
    end

    test "backoff is capped at an hour" do
      block = block_at(0, "header_only")
      results = for _ <- 1..9, do: run(block)

      assert results |> Enum.map(fn {:snooze, s} -> s end) ==
               [60, 120, 240, 480, 960, 1920, 3600, 3600, 3600]
    end

    test "a stall of more than an hour sends exactly one alert" do
      block = block_at(0, "header_only")

      # Six failures back off 1+2+4+8+16+32 = 63 minutes: the seventh is the
      # first more than an hour after the first.
      for _ <- 1..6, do: run(block)
      refute_email_sent()

      run(block)
      assert_email_sent(subject: "Bitblocks: sync stalled at block 0")

      for _ <- 1..3, do: run(block)
      refute_email_sent()
    end
  end

  describe "the loop" do
    test "the cron doesn't start a second loop while one is queued or running" do
      {:ok, first} = Oban.insert(SyncWorker.new(%{}))
      {:ok, second} = Oban.insert(SyncWorker.new(%{}))
      assert second.conflict?
      assert second.id == first.id

      Repo.update_all(Oban.Job, set: [state: "executing"])
      {:ok, third} = Oban.insert(SyncWorker.new(%{}))
      assert third.conflict?
    end

    test "the cron's job makes sure the coordinator is running" do
      assert :ok = perform_job(SyncWorker, %{})
      assert is_pid(Process.whereis(Bitblocks.Sync.Coordinator))
    end
  end

  describe "the coordinator" do
    # Two coordinators stand in for two app nodes; an Agent says which one
    # Oban elected leader.
    defp start_node(name, leader) do
      start_supervised!(
        {Coordinator,
         name: name,
         auto: false,
         headers: false,
         leader?: fn -> Agent.get(leader, & &1) == name end},
        id: name
      )
    end

    test "only the leader dispatches, and leadership hands over cleanly" do
      Application.put_env(:bitblocks, :sync_workers, 1)
      {:ok, leader} = Agent.start_link(fn -> :node_a end)
      a = start_node(:node_a, leader)
      b = start_node(:node_b, leader)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), a)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), b)

      block_at(0, "header_only")
      block_at(1, "header_only")

      assert %{leading: true} = Coordinator.tick(a)
      assert %{leading: false} = Coordinator.tick(b)
      assert dispatched_hashes() == ["block_0"]

      # Leadership moves to b: a stands down, b takes over the same slots.
      Agent.update(leader, fn _ -> :node_b end)
      assert %{leading: false} = Coordinator.tick(a)
      assert %{leading: true} = Coordinator.tick(b)
      assert dispatched_hashes() == ["block_0"]
    end

    test "a completed block's slot goes to the next block" do
      Application.put_env(:bitblocks, :sync_workers, 1)
      {:ok, leader} = Agent.start_link(fn -> :node_a end)
      a = start_node(:node_a, leader)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), a)

      block_at(0, "header_only")
      block_at(1, "header_only")
      stub_bodies(["tx-0"])

      Coordinator.tick(a)
      [job] = all_enqueued(worker: FetchTransactionsWorker)
      assert job.meta["slot"] == 1
      assert :ok = FetchTransactionsWorker.perform(job)
      Repo.update_all(Oban.Job, set: [state: "completed"])

      Coordinator.tick(a)

      assert [%{args: %{"block_hash" => "block_1"}, meta: %{"slot" => 1}}] =
               all_enqueued(worker: FetchTransactionsWorker)
    end
  end

  describe "concurrency" do
    test "is clamped to the computed limit, and the reason is named" do
      Application.put_env(:bitblocks, :sync_rpc_limit, 2)
      on_exit(fn -> Application.put_env(:bitblocks, :sync_rpc_limit, 4) end)

      assert {2, "node RPC threads"} = Sync.concurrency_limit()
      assert {:ok, 2} = Sync.set_concurrency(9)
      assert Sync.concurrency() == 2
      assert {:ok, 1} = Sync.set_concurrency(0)
    end

    test "shrinking lets live blocks finish and refills nothing until a slot frees" do
      for h <- 0..3, do: block_at(h, "header_only")
      assert Sync.dispatch(2) == 2
      assert Sync.dispatch(1) == 0
      assert dispatched_hashes() == ["block_0", "block_1"]
    end
  end
end
