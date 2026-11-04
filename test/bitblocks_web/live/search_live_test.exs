defmodule BitblocksWeb.SearchLiveTest do
  # The connected LiveView reads this test's rows, so not async.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  test "a pasted txid finds the transaction and the block it is in", %{conn: conn} do
    block = block_fixture()
    txid = String.duplicate("7e", 32)
    tx = transaction_fixture(%{txid: txid, block_hash: block.hash, block_height: block.height})

    {:ok, _view, html} = live(conn, "/search?query=#{tx.txid}")

    assert html =~ tx.txid
    assert html =~ ~s(href="/transactions/#{tx.txid}")
    assert html =~ block.hash
  end

  test "a block height finds the block", %{conn: conn} do
    block = block_fixture()

    {:ok, _view, html} = live(conn, "/search?query=#{block.height}")

    assert html =~ "/blocks/#{block.height}"
  end

  test "a txid we don't store says so", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/search?query=#{String.duplicate("ab", 32)}")

    assert html =~ "not found"
  end
end
