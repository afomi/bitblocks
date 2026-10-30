defmodule BitblocksWeb.RexxiesLiveTest do
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.OrdinalCollections.Item

  # Rexxie #1's mint, from the bundled catalog.
  @mint "52c8ee4935f983b7ce10b84882cb42b30d989a4385eaec1289fafe88325eb53f"

  test "the detail panel shows the holder traced by the chain index (#30)", %{conn: conn} do
    Bitblocks.Repo.insert!(%Item{
      collection_id: Bitblocks.OrdinalCollections.known()["rexxies"],
      origin: "#{@mint}_3",
      mint_txid: @mint,
      current_outpoint: "#{String.duplicate("d", 64)}_1",
      owner: "1HolderXXXXXXXXXXXXXXXXXXXXXXXXXXX",
      trace_state: "current"
    })

    {:ok, view, _html} = live(conn, ~p"/collections/rexxies")
    html = render_click(view, "select_nft", %{"number" => "1"})

    assert html =~ "rexxie-holder"
    assert view |> element("#rexxie-holder") |> render() =~ "1HolderXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  end

  test "without an indexed holding the panel shows no holder row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/collections/rexxies")
    render_click(view, "select_nft", %{"number" => "1"})

    refute has_element?(view, "#rexxie-holder")
  end
end
