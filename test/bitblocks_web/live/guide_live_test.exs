defmodule BitblocksWeb.GuideLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders guide page with content sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/guide")

    assert html =~ "Understanding Bitcoin"
    assert html =~ "What is a Block?"
    assert html =~ "What is a Transaction?"
    assert html =~ "Data on the Blockchain"
    assert html =~ "Identity on Bitcoin"
    assert html =~ "The Network"
    assert html =~ "Further Reading"
  end

  test "links to Bitblocks features", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/guide")

    assert html =~ "/blocks"
    assert html =~ "/block-graph"
    assert html =~ "/transactions"
    assert html =~ "/tx-graph"
    assert html =~ "/protocols"
    assert html =~ "/ecosystem"
    assert html =~ "/did"
    assert html =~ "/peers"
    assert html =~ "/pulse"
  end

  test "links to external resources", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/guide")

    assert html =~ "bitcoin.org/bitcoin.pdf"
    assert html =~ "learnmeabitcoin.com"
  end
end
