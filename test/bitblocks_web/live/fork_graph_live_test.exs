defmodule BitblocksWeb.ForkGraphLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Bitblocks.ForkTracker
  alias BitblocksWeb.RpcStub

  setup do
    RpcStub.setup()
    Application.put_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCliMock)
    ForkTracker.reset()

    on_exit(fn ->
      Application.delete_env(:bitblocks, :bitcoinsv_cli)
      ForkTracker.reset()
      RpcStub.clear()
    end)

    seed_headers()

    tips = [
      %{"hash" => "main_50", "height" => 50, "branchlen" => 0, "status" => "active"},
      %{"hash" => "fork_50", "height" => 50, "branchlen" => 1, "status" => "valid-fork"}
    ]

    RpcStub.stub_getchaintips(tips)
    ForkTracker.ingest_chaintips(tips, source: "mock")
    _ = ForkTracker.snapshot()

    :ok
  end

  test "renders fork graph view", %{conn: conn} do
    {:ok, view, html} = live(conn, "/forks", on_error: :warn)

    assert html =~ "Fork Topology"
    assert render(view) =~ "Active chain tips"
  end

  defp seed_headers do
    RpcStub.stub_getblockheader("main_50", true, header("main_50", 50, "main_49"))
    RpcStub.stub_getblockheader("main_49", true, header("main_49", 49, "main_48"))
    RpcStub.stub_getblockheader("fork_50", true, header("fork_50", 50, "fork_49"))
    RpcStub.stub_getblockheader("fork_49", true, header("fork_49", 49, "main_48"))
    RpcStub.stub_getblockheader("main_48", true, header("main_48", 48, nil))
  end

  defp header(hash, height, parent) do
    %{
      "hash" => hash,
      "height" => height,
      "time" => 1_700_000_000 + height,
      "chainwork" => Integer.to_string(75_000 + height, 16),
      "previousblockhash" => parent
    }
  end
end
