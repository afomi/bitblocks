defmodule BitblocksWeb.TxGraphLiveTest do
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.FirstSpendFixtures

  alias BitblocksWeb.TxGraphLive

  test "opens on the first 1,000 blocks, with the scene and its controls", %{conn: conn} do
    {:ok, view, html} = live(conn, "/tx-graph")
    assert html =~ "Transaction flow"
    assert has_element?(view, ~s(#tx-flow[phx-hook="TxFlow"][data-from="0"][data-to="999"]))
    assert has_element?(view, "#tx-flow-play[type=range]")
    assert has_element?(view, "#tx-flow-minimap")
    assert has_element?(view, ~s(label[for="tx-flow-from"]))
  end

  test "a range in the query opens that range", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tx-graph?from=100&to=300")
    assert has_element?(view, ~s(#tx-flow[data-from="100"][data-to="300"]))
  end

  test "a txid opens the blocks around it", %{conn: conn} do
    insert_first_spend()
    {:ok, view, _html} = live(conn, "/tx-graph?txid=#{first_spend()}")

    assert has_element?(
             view,
             ~s(#tx-flow[data-from="70"][data-to="270"][data-txid="#{first_spend()}"])
           )
  end

  test "a txid we don't hold says so and opens the default range", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tx-graph?txid=#{String.duplicate("e", 64)}")
    assert has_element?(view, "#tx-flow-error", "isn't stored")
  end

  test "range/2 caps a range at the block limit" do
    {from, to, nil} = TxGraphLive.range(%{"from" => "0", "to" => "99999999"}, "")
    assert {from, to} == {0, Bitblocks.ChainFlow.max_blocks() - 1}
  end

  test "annotation changes are pushed to the scene", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tx-graph")
    # The mount push first: reorgs and classified losses, no events yet.
    assert_push_event(view, "annotations", %{items: at_mount})
    refute Enum.any?(at_mount, &(&1.kind == "event"))

    {:ok, _} =
      Bitblocks.Annotations.create(%{kind: "milestone", title: "First spend", height: 170})

    assert_push_event(view, "annotations", %{items: items})
    assert Enum.any?(items, &(&1.label == "First spend" and &1.kind == "event"))
  end
end
