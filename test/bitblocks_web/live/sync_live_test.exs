defmodule BitblocksWeb.SyncLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures
  import Ecto.Query

  alias Bitblocks.Repo

  describe "completeness audit" do
    test "renders the audit card, not yet run", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sync")

      assert html =~ "Completeness Audit"
      assert html =~ "Not run yet"
    end

    test "run_audit surfaces a completed block with missing transactions", %{conn: conn} do
      block =
        block_fixture(%{
          height: 810_001,
          hash: "sync_live_deficit",
          num_tx: 3,
          sync_state: "completed"
        })

      transaction_fixture(%{block_hash: block.hash})

      {:ok, view, _html} = live(conn, ~p"/sync")

      view |> element("button", "Run Audit") |> render_click()
      html = render_async(view)

      assert html =~ "1 block(s) with missing transactions"
      assert html =~ "810001"
      assert html =~ "completed"
    end

    test "run_audit reports a clean database", %{conn: conn} do
      block =
        block_fixture(%{
          height: 810_002,
          hash: "sync_live_clean",
          num_tx: 1,
          sync_state: "completed"
        })

      transaction_fixture(%{block_hash: block.hash})

      {:ok, view, _html} = live(conn, ~p"/sync")

      view |> element("button", "Run Audit") |> render_click()
      html = render_async(view)

      assert html =~ "No deficits"
    end

    test "repair resets flagged blocks and enqueues the sequential backfill", %{conn: conn} do
      block =
        block_fixture(%{
          height: 810_003,
          hash: "sync_live_repair",
          num_tx: 2,
          sync_state: "completed"
        })

      {:ok, view, _html} = live(conn, ~p"/sync")

      view |> element("button", "Run Audit") |> render_click()
      render_async(view)

      view |> element("button", "Repair") |> render_click()
      render_async(view)

      assert Repo.reload!(block).sync_state == "header_synced"

      assert Repo.exists?(
               from(j in Oban.Job,
                 where: j.worker == "Bitblocks.Workers.BackfillTransactionsWorker"
               )
             )
    end
  end
end
