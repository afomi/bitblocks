defmodule BitblocksWeb.NodeStatusPagesTest do
  # A node answering -28 ("Verifying blocks...", "Loading block index...") is
  # reachable and warming up after a restart, not unreachable (2026-11-04).
  use ExUnit.Case, async: true

  alias Bitblocks.Config

  @warming {:error, %{"code" => -28, "message" => "Verifying blocks..."}}

  test "classifies a warm-up answer apart from a failure" do
    assert {:warming_up, "Verifying blocks..."} = Config.node_status(@warming)
    assert {:unreachable, _} = Config.node_status({:error, :econnrefused})
    assert :ok = Config.node_status(%{"chain" => "main", "blocks" => 1})
  end

  test "/debug says the node is starting, not that it can't connect" do
    html =
      Phoenix.Template.render_to_string(BitblocksWeb.PageHTML, "debug", "html",
        blockchain_info: @warming,
        bitcoin_url: "http://node:8332",
        rpc_user: "bitblocks"
      )

    assert html =~ "starting up"
    assert html =~ "Verifying blocks..."
    refute html =~ "Cannot connect"
  end

  test "pages never show the node's address" do
    assert Config.masked_node_url("http://203.0.113.5:8332") == "http://•••:8332"

    html =
      Phoenix.Template.render_to_string(BitblocksWeb.PageHTML, "debug", "html",
        blockchain_info: @warming,
        bitcoin_url: "http://203.0.113.5:8332",
        rpc_user: "bitblocks"
      )

    refute html =~ "203.0.113.5"
  end
end
