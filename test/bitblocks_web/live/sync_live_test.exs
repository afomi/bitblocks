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

    test "repair reopens flagged completed blocks for the sync loop", %{conn: conn} do
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
    end
  end

  describe "worker slots" do
    test "an admin's choice is clamped to the limit, named, and applied", %{conn: conn} do
      Application.put_env(:bitblocks, :sync_rpc_limit, 2)
      # One block per job, so each slot holds its own block (no small-block runs).
      Application.put_env(:bitblocks, :sync_run_max_blocks, 1)

      on_exit(fn ->
        Application.put_env(:bitblocks, :sync_rpc_limit, 4)
        Application.delete_env(:bitblocks, :sync_run_max_blocks)
      end)

      {:ok, view, _html} = live(conn, ~p"/sync")
      assert has_element?(view, "#sync-concurrency-limit", "Max 2 — node RPC threads")
      assert has_element?(view, "#sync-concurrency[value='1']")

      html =
        view
        |> form("#sync-concurrency-form", %{"concurrency" => "8"})
        |> render_submit()

      assert html =~ ~s(value="2")
      assert Bitblocks.Sync.concurrency() == 2

      # The coordinator applies it: two slots, the lowest two blocks.
      for h <- 0..2, do: block_fixture(%{height: h, num_tx: 1, sync_state: "header_only"})

      {:ok, coordinator} =
        Bitblocks.Sync.Coordinator.start_link(
          name: :slots_test,
          leader?: fn -> true end,
          auto: false,
          headers: false
        )

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), coordinator)
      assert %{leading: true, concurrency: 2} = Bitblocks.Sync.Coordinator.tick(coordinator)

      assert Repo.all(from(j in Oban.Job, select: j.meta["slot"], order_by: j.id)) == [1, 2]
    end
  end
end
