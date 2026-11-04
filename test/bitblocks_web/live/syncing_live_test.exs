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
    |> Tracker.new("transactions_tip", 5)
    |> Tracker.chunk([a.txid, b.txid, c.txid])
    |> Tracker.finish()

    SyncProgress.flush()

    {:ok, view, html} = live(conn, ~p"/syncing")

    assert html =~ "Syncing now"
    assert has_element?(view, "#syncing-#{block.hash} a[href='/blocks/970001']", "Block 970,001")
    assert has_element?(view, "#syncing-#{block.hash}", "Tip lane")
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
      lane: "transactions_backfill",
      total: 4_000,
      stored: 1_234,
      processed: 1_200
    }

    Phoenix.PubSub.broadcast(Bitblocks.PubSub, Tracker.topic(), {:sync_progress, progress})
    SyncProgress.flush()

    assert has_element?(view, "#syncing-#{block.hash}-synced-count", "1,234 of 4,000")
    assert has_element?(view, "#syncing-#{block.hash}-processed-count", "1,200 of 4,000")
    assert has_element?(view, "#syncing-#{block.hash}", "Backfill lane")

    # The worker's final report, then completion: the block moves to recent
    # with the worker's counts, and nothing is counted again.
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

    refute has_element?(view, "#syncing-#{block.hash}")
    assert has_element?(view, "#recent-#{block.hash}-synced-count", "4,000 of 4,000")
    assert has_element?(view, "#recent-#{block.hash}-processed-count", "3,990 of 4,000")
  end

  test "the overall picture shows our tip and blocks by sync state", %{conn: conn} do
    block_fixture(%{height: 970_100, sync_state: "header_only"})
    SyncProgress.refresh()

    {:ok, view, _html} = live(conn, ~p"/syncing")

    assert has_element?(view, "#our-tip", "970,100")
    assert has_element?(view, "#sync-states")
    assert has_element?(view, "#syncing-empty", "No block is fetching transactions right now.")
  end
end
