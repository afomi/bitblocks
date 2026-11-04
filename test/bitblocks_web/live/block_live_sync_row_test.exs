defmodule BitblocksWeb.BlockLiveSyncRowTest do
  # /blocks shows the blocks being synced right now, one row each: height,
  # tx count and how many are downloaded, from the shared /syncing snapshot.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.SyncProgress

  defp publish(rows) do
    overview = %{
      tip: 973_000,
      complete_through: 162_000,
      target: 162_001,
      in_use: 1,
      concurrency: 2,
      limit: 2,
      max_concurrency: 2,
      limit_reason: "CPU cores",
      rows: rows
    }

    send(Process.whereis(SyncProgress), {:sync_overview, overview})
    SyncProgress.flush()
  end

  test "a block being worked shows its tx count and downloaded count in one row", %{conn: conn} do
    publish([
      %{
        height: 162_001,
        hash: "h1",
        num_tx: 4_000,
        sync_state: "txs_syncing",
        slot: 1,
        job_state: "executing"
      },
      %{height: 162_002, hash: "h2", num_tx: 10, fetched: nil, sync_state: "header_only"}
    ])

    # The worker's own count, as FetchTransactionsWorker reports it.
    Phoenix.PubSub.broadcast(
      Bitblocks.PubSub,
      Bitblocks.SyncProgress.Tracker.topic(),
      {:sync_progress,
       %{
         hash: "h1",
         height: 162_001,
         time: 0,
         num_tx: 4_000,
         total: 4_000,
         stored: 1_234,
         processed: 1_234
       }}
    )

    SyncProgress.flush()

    {:ok, _view, html} = live(conn, "/blocks")

    assert html =~ ~s(id="sync-row-162001")
    assert html =~ "1,234 of 4,000"
    # Only blocks a worker holds; the waiting one stays on /syncing.
    refute html =~ ~s(id="sync-row-162002")
    assert html =~ ~s(href="/syncing")
  end

  test "a block in the list whose txs are loading carries its own bar", %{conn: conn} do
    loading = Bitblocks.ChainFixtures.block_fixture(height: 155_001, num_tx: 400)
    idle = Bitblocks.ChainFixtures.block_fixture(height: 155_000, num_tx: 2)

    working = [
      %{
        height: 155_001,
        hash: loading.hash,
        num_tx: 400,
        sync_state: "txs_syncing",
        slot: 1,
        job_state: "executing"
      }
    ]

    publish(working)
    report(loading.hash, 100)

    {:ok, view, _html} = live(conn, "/blocks")

    assert has_element?(view, "#block-155001 #block-progress-155001", "100 of 400 loaded · 25%")
    assert has_element?(view, ~s(#block-155001 [role="progressbar"][aria-valuenow="25"]))
    refute has_element?(view, "#block-#{idle.height} [role=progressbar]")

    # The worker reports more; the bar follows the shared snapshot.
    report(loading.hash, 300)
    publish(working)
    assert render(view) =~ "300 of 400 loaded"

    # Done: the job lets go of the block and the bar goes.
    publish([])
    refute has_element?(view, "#block-155001 [role=progressbar]")
  end

  # The worker's own count, as FetchTransactionsWorker reports it.
  defp report(hash, stored) do
    Phoenix.PubSub.broadcast(
      Bitblocks.PubSub,
      Bitblocks.SyncProgress.Tracker.topic(),
      {:sync_progress,
       %{
         hash: hash,
         height: 155_001,
         time: 0,
         num_tx: 400,
         total: 400,
         stored: stored,
         processed: stored
       }}
    )

    SyncProgress.flush()
  end

  test "with nothing being worked, no sync rows", %{conn: conn} do
    publish([])
    {:ok, _view, html} = live(conn, "/blocks")
    refute html =~ ~s(id="sync-row-)
  end
end
