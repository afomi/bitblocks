defmodule Bitblocks.SyncOrderingTest do
  use Bitblocks.DataCase, async: false
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.ChainFixtures
  alias Bitblocks.{Chain, Sync}
  alias Bitblocks.Workers.FetchTransactionsWorker

  setup context do
    previous = Application.get_env(:bitblocks, :sync_run_max_blocks)
    Application.put_env(:bitblocks, :sync_run_max_blocks, 1)
    unless context[:external_lock], do: Sync.set_concurrency(2)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bitblocks, :sync_run_max_blocks, previous),
        else: Application.delete_env(:bitblocks, :sync_run_max_blocks)
    end)

    :ok
  end

  test "waits for genesis rather than assigning a later stored block" do
    block_fixture(%{height: 1, sync_state: "header_only"})
    assert Sync.dispatch() == 0
    assert all_enqueued(worker: FetchTransactionsWorker) == []
  end

  test "doesn't dispatch past a missing header inside the window" do
    block_fixture(%{height: 0, sync_state: "completed"})
    block_fixture(%{height: 2, sync_state: "header_only"})
    assert Sync.dispatch() == 0

    block_fixture(%{height: 1, sync_state: "header_only"})
    assert Sync.dispatch() == 2
  end

  test "a stalled first block bounds how far the other slot can advance" do
    for h <- 0..3,
        do: block_fixture(%{height: h, hash: "ordered-#{h}", sync_state: "header_only"})

    assert Sync.dispatch() == 2

    Chain.get_block_at_height(1)
    |> Ecto.Changeset.change(sync_state: "completed")
    |> Repo.update!()

    from(j in Oban.Job, where: j.args["block_hash"] == "ordered-1")
    |> Repo.update_all(set: [state: "completed"])

    assert Sync.dispatch() == 0
    assert Sync.complete_through() == -1
  end

  test "direct dispatch honors the persisted pause and concurrency" do
    for h <- 0..5, do: block_fixture(%{height: h, sync_state: "header_only"})
    Sync.set_concurrency(1)
    Sync.set_paused(true)
    assert Sync.dispatch(999) == 0

    Sync.set_paused(false)
    assert Sync.dispatch(999) == 1
  end

  test "requesting a distant block cannot bypass the ordered dispatcher" do
    distant = block_fixture(%{height: 200, sync_state: "header_only"})
    assert {:ok, _} = Chain.queue_transaction_fetch(distant)
    assert all_enqueued(worker: FetchTransactionsWorker) == []
    assert Repo.reload!(distant).sync_state == "header_only"
  end

  @tag :external_lock
  test "dispatch waits for the cluster lock held on another database connection" do
    block_fixture(%{height: 0, sync_state: "header_only"})
    parent = self()

    holder =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [728_193_042])
            send(parent, :lock_held)

            receive do
              :release -> :ok
            after
              5_000 -> raise "test did not release the dispatcher lock"
            end
          end)
        end)
      end)

    assert_receive :lock_held, 2_000
    dispatcher = Task.async(fn -> Sync.dispatch() end)

    try do
      ref = dispatcher.ref
      refute_receive {^ref, _result}, 100
    after
      send(holder.pid, :release)
    end

    Task.await(holder)
    assert Task.await(dispatcher) == 1
    assert length(all_enqueued(worker: FetchTransactionsWorker)) == 1
  end
end
