defmodule BitblocksWeb.SyncingOperatorTest do
  # The operator panel on /syncing. config/test.exs turns the gate off, so the
  # viewer here is an admin; test/bitblocks_web/user_auth_test.exs covers a
  # reader with the gate on.
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures
  import Ecto.Query

  alias Bitblocks.Repo

  describe "completeness audit" do
    test "renders the audit card, not yet run", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/syncing")

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

      {:ok, view, _html} = live(conn, ~p"/syncing")

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

      {:ok, view, _html} = live(conn, ~p"/syncing")

      view |> element("button", "Run Audit") |> render_click()
      html = render_async(view)

      assert html =~ "No deficits"
    end
  end

  # #44: the page says what the loop and the buttons actually do.
  describe "matches what it does" do
    test "leads with the health sentence", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/syncing")
      assert has_element?(view, "#sync-health")
    end

    test "the failed count opens the failed heights, with their error", %{conn: conn} do
      block_fixture(%{
        height: 810_010,
        sync_state: "failed",
        tx_sync_attempts: 3,
        tx_sync_error: "merkle mismatch"
      })

      {:ok, view, _html} = live(conn, ~p"/syncing")

      assert has_element?(view, "#sync-failed-blocks a[href='/blocks/810010']")
      assert has_element?(view, "#sync-failed-blocks", "merkle mismatch")
      assert has_element?(view, "#sync-failed-blocks", "3 in a row")
    end

    test "lists webhook deliveries given up on, with the projection and last status", %{
      conn: conn
    } do
      {:ok, projection} =
        Bitblocks.Projections.create(%{
          tenant: "visible-dao",
          name: "donations",
          filter: %{"output_addresses" => ["1Donation"]},
          webhook_url: "https://hooks.example/bitblocks"
        })

      {:ok, view, _html} = live(conn, ~p"/syncing")
      refute has_element?(view, "#sync-webhook-failures")

      Bitblocks.Projections.record_webhook_failure(projection, "tx", "{:http_status, 500}")

      {:ok, view, _html} = live(conn, ~p"/syncing")
      assert has_element?(view, "#sync-webhook-failures", "visible-dao/donations")
      assert has_element?(view, "#sync-webhook-failures", "{:http_status, 500}")
    end

    test "the audit's confirm says it scans transactions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/syncing")
      assert has_element?(view, "button[data-confirm*='scans the whole transactions table']")
    end

    test "keeps failures in view and the audit closed", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/syncing")

      refute html =~ "Sync a Range"
      refute has_element?(view, "form[phx-submit='start_sync']")
      assert has_element?(view, "details#sync-diagnostics:not([open])")
    end

    test "pause stops new dispatch and says so; resume starts it again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/syncing")
      assert has_element?(view, "#sync-pause-state", "Running")

      view |> element("#sync-pause button", "Pause the sync") |> render_click()

      assert Bitblocks.Sync.paused?()
      assert has_element?(view, "#sync-pause-state", "Paused")
      assert has_element?(view, "#sync-pause-state", "No new blocks are dispatched")

      view |> element("#sync-pause button", "Resume the sync") |> render_click()

      refute Bitblocks.Sync.paused?()
      assert has_element?(view, "#sync-pause-state", "Running")
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

      {:ok, view, _html} = live(conn, ~p"/syncing")
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
