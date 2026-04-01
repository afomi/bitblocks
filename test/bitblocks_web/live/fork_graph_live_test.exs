defmodule BitblocksWeb.ForkGraphLiveTest do
  use BitblocksWeb.ConnCase
  use ExVCR.Mock, adapter: ExVCR.Adapter.Hackney

  import Phoenix.LiveViewTest

  alias Bitblocks.ForkTracker

  setup do
    ForkTracker.reset()

    on_exit(fn ->
      ForkTracker.reset()
    end)

    :ok
  end

  test "renders fork graph view", %{conn: conn} do
    use_cassette "fork_graph_live/render_fork_graph", record: :none do
      tips = [
        %{"hash" => "main_50", "height" => 50, "branchlen" => 0, "status" => "active"},
        %{"hash" => "fork_50", "height" => 50, "branchlen" => 1, "status" => "valid-fork"}
      ]

      ForkTracker.ingest_chaintips(tips, source: "mock")
      Process.sleep(100)
      _ = ForkTracker.snapshot()

      {:ok, view, html} = live(conn, "/forks", on_error: :warn)

      assert html =~ "Fork Topology"
      assert render(view) =~ "Active chain tips"
    end
  end
end
