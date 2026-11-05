defmodule BitblocksWeb.GraphLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  test "draws the graph from the query string", %{conn: conn} do
    center = transaction_fixture()
    transaction_fixture(%{input_txids: [center.txid]})

    {:ok, view, _html} = live(conn, ~p"/graph?txid=#{center.txid}&depth=2")

    assert render(view) =~ "2 transactions, 1 connections"
  end

  test "an unusable depth falls back, and an unknown txid says so", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/graph?txid=nope&depth=junk")

    assert html =~ "Transaction not found"
  end
end
