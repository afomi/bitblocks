defmodule BitblocksWeb.SeoAndPulseTest do
  use BitblocksWeb.ConnCase, async: true

  alias Floki

  test "home page emits canonical and social urls", %{conn: conn} do
    document =
      conn
      |> get(~p"/")
      |> html_response(200)
      |> Floki.parse_document!()

    assert Floki.attribute(document, "link[rel='canonical']", "href") == [
             "https://bitblocks.app/"
           ]

    assert Floki.attribute(document, "meta[property='og:url']", "content") == [
             "https://bitblocks.app/"
           ]

    assert Floki.attribute(document, "meta[name='twitter:url']", "content") == [
             "https://bitblocks.app/"
           ]
  end

  test "search page is noindex with a stable canonical", %{conn: conn} do
    document =
      conn
      |> get(~p"/search?query=123")
      |> html_response(200)
      |> Floki.parse_document!()

    assert Floki.attribute(document, "meta[name='robots']", "content") == ["noindex, follow"]

    assert Floki.attribute(document, "link[rel='canonical']", "href") == [
             "https://bitblocks.app/search"
           ]
  end

  test "pulse page renders the experimental visualization shell", %{conn: conn} do
    document =
      conn
      |> get(~p"/pulse")
      |> html_response(200)
      |> Floki.parse_document!()

    assert Floki.attribute(document, "#network-pulse-canvas", "phx-hook") == ["NetworkPulse"]
    assert Floki.attribute(document, "meta[name='robots']", "content") == ["noindex, follow"]
    assert document |> Floki.find("h1") |> Floki.text() =~ "Network Pulse"
  end
end
