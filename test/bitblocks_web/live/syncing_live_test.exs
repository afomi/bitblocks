defmodule BitblocksWeb.SyncingLiveTest do
  # The shared SyncProgress server reads rows inserted by the test.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  alias Bitblocks.{Repo, SyncProgress, TransactionParser}
  alias Bitblocks.SyncProgress.Tracker

  defp syncing_block(attrs) do
    block = block_fixture(attrs)

    block
    |> Ecto.Changeset.change(%{sync_state: Map.get(attrs, :sync_state, "txs_syncing")})
    |> Repo.update!()
  end

  defp stored_tx(block, version) do
    tx = transaction_fixture(%{block_hash: block.hash, block_height: block.height})

    tx
    |> Ecto.Changeset.change(%{script_analysis_version: version})
    |> Repo.update!()
  end

  setup do
    # Start each test from this test's rows, not an earlier test's.
    SyncProgress.refresh()
    :ok
  end

  test "a syncing block shows synced and processed as x of y", %{conn: conn} do
    block = syncing_block(%{height: 970_001, num_tx: 5, time: 1_762_000_000})

    current = TransactionParser.script_analysis_version()
    a = stored_tx(block, current)
    b = stored_tx(block, current)
    c = stored_tx(block, current - 1)

    # What the worker does as it walks the block: count the chunk it just stored.
    block
    |> Tracker.new(5)
    |> Tracker.chunk([a.txid, b.txid, c.txid])
    |> Tracker.finish()

    SyncProgress.flush()

    {:ok, view, html} = live(conn, ~p"/syncing")

    assert html =~ "Syncing now"
    assert has_element?(view, "#syncing-#{block.hash} a[href='/blocks/970001']", "Block 970,001")
    assert has_element?(view, "#syncing-#{block.hash}", "txs_syncing")
    assert has_element?(view, "#syncing-#{block.hash}-synced-count", "3 of 5")
    assert has_element?(view, "#syncing-#{block.hash}-processed-count", "2 of 5")

    assert has_element?(
             view,
             "#syncing-#{block.hash}-synced [role='progressbar'][aria-valuenow='3'][aria-valuemax='5']"
           )

    assert has_element?(
             view,
             "#syncing-#{block.hash}-processed [role='progressbar'][aria-valuetext='2 of 5']"
           )
  end

  test "progress arriving over PubSub updates the page live", %{conn: conn} do
    block = syncing_block(%{height: 970_002, num_tx: 4_000})
    SyncProgress.refresh()

    {:ok, view, _html} = live(conn, ~p"/syncing")

    assert has_element?(view, "#syncing-#{block.hash}-synced-count", "Starting")

    progress = %{
      hash: block.hash,
      height: block.height,
      time: block.time,
      num_tx: 4_000,
      total: 4_000,
      stored: 1_234,
      processed: 1_200
    }

    Phoenix.PubSub.broadcast(Bitblocks.PubSub, Tracker.topic(), {:sync_progress, progress})
    SyncProgress.flush()

    assert has_element?(view, "#syncing-#{block.hash}-synced-count", "1,234 of 4,000")
    assert has_element?(view, "#syncing-#{block.hash}-processed-count", "1,200 of 4,000")

    # The worker's final report, then completion: the block stays in place,
    # verified, with the worker's counts, and nothing is counted again.
    Phoenix.PubSub.broadcast(
      Bitblocks.PubSub,
      Tracker.topic(),
      {:sync_progress, %{progress | stored: 4_000, processed: 3_990}}
    )

    completed =
      block
      |> Ecto.Changeset.change(%{
        sync_state: "completed",
        tx_sync_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

    Bitblocks.Chain.broadcast_block_update(completed)
    SyncProgress.flush()

    assert has_element?(view, "#syncing-#{block.hash}[data-finished]")
    assert has_element?(view, "#syncing-#{block.hash}-synced-count", "4,000 of 4,000")
    assert has_element?(view, "#syncing-#{block.hash}-processed-count", "3,990 of 4,000")
  end

  test "the overall picture shows our tip and blocks by sync state", %{conn: conn} do
    block_fixture(%{height: 970_100, sync_state: "header_only"})
    SyncProgress.refresh()

    {:ok, view, _html} = live(conn, ~p"/syncing")

    assert has_element?(view, "#our-tip", "970,100")
    assert has_element?(view, "#sync-states")
    assert has_element?(view, "#syncing-empty")
  end

  test "the block table shows each block's stages in height order", %{conn: conn} do
    for h <- 0..1, do: block_fixture(%{height: h, num_tx: 1, sync_state: "completed"})
    block_fixture(%{height: 2, hash: "table_two", num_tx: 3, sync_state: "failed"})
    block_fixture(%{height: 3, hash: "table_three", num_tx: 2, sync_state: "header_only"})

    {:ok, _job} =
      Oban.insert(
        Bitblocks.Workers.FetchTransactionsWorker.new(%{block_hash: "table_two"},
          meta: %{slot: 1}
        )
      )

    SyncProgress.refresh()
    {:ok, view, html} = live(conn, ~p"/syncing")

    assert has_element?(view, "#sync-table-heading", "Complete through block 1 of 3 known")
    assert has_element?(view, "#sync-table-row-1", "Verified")
    assert has_element?(view, "#sync-table-row-1", "Complete through here")
    assert has_element?(view, "#sync-table-row-2", "Slot 1, queued")
    assert has_element?(view, "#sync-table-row-2", "The target")
    assert has_element?(view, "#sync-table-row-2-fetched", "Not started")
    assert has_element?(view, "#sync-table-row-3", "Waiting for a slot")

    rows = Regex.scan(~r/id="sync-table-row-(\d+)"/, html) |> Enum.map(fn [_, h] -> h end)
    assert rows == ["1", "2", "3"]
  end

  describe "the board: one list in height order, finished blocks fade in place" do
    @now ~U[2026-11-04 12:00:00Z]

    defp done(height, seconds_ago),
      do: %{
        hash: "h#{height}",
        height: height,
        sync_state: "completed",
        tx_sync_completed_at: DateTime.add(@now, -seconds_ago, :second)
      }

    defp working(height), do: %{hash: "h#{height}", height: height, sync_state: "txs_syncing"}

    test "working and just-finished blocks share one list, lowest height first" do
      board =
        BitblocksWeb.SyncingLive.board([working(5), working(3)], [done(4, 10), done(2, 50)], @now)

      assert Enum.map(board, & &1.height) == [2, 3, 4, 5]
    end

    test "a finished block holds for 45 s, fades to 60 s, then leaves" do
      board =
        BitblocksWeb.SyncingLive.board([], [done(4, 10), done(2, 52), done(1, 70)], @now)

      by = Map.new(board, &{&1.height, &1})
      assert by[4].finished and by[4].opacity == 1.0
      assert by[2].finished and by[2].opacity < 1.0 and by[2].opacity > 0
      refute Map.has_key?(by, 1)
    end

    test "a working block is never faded" do
      [entry] = BitblocksWeb.SyncingLive.board([working(9)], [], @now)
      refute entry.finished
      assert entry.opacity == 1.0
    end
  end
end
