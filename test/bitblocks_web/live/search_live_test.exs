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

  test "a block hash finds the block", %{conn: conn} do
    block = block_fixture(%{hash: String.duplicate("0a", 32)})

    {:ok, _view, html} = live(conn, "/search?query=#{block.hash}")

    assert html =~ "Block Found"
    assert html =~ "/blocks/#{block.height}"
  end

  test "a height past the index says it isn't indexed yet", %{conn: conn} do
    block = block_fixture()
    height = block.height + 1_000

    {:ok, _view, html} = live(conn, "/search?query=#{height}")

    assert html =~ "is not indexed yet"
    assert html =~ "The highest block we know"
    refute html =~ "look like"
  end

  test "a height no column can hold reads the same, not a crash", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/search?query=99999999999999999999")

    assert html =~ "is not indexed yet"
  end

  test "a nonsense query says what to enter, not that it's missing", %{conn: conn} do
    for query <- ["hello", "abc123", "-5"] do
      {:ok, _view, html} = live(conn, "/search?query=#{query}")

      assert html =~ "look like a block height"
      refute html =~ "not indexed yet"
    end
  end
end
