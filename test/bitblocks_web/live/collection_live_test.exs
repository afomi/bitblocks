defmodule BitblocksWeb.CollectionLiveTest do
  # The LiveView process has to see rows inserted by the test.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.Repo

  defp item!(collection_id, n, attrs \\ %{}) do
    txid = String.pad_leading(Integer.to_string(n, 16), 64, "0") |> String.downcase()

    Repo.insert!(
      struct!(
        %Item{
          collection_id: collection_id,
          origin: "#{txid}_0",
          mint_txid: txid,
          mint_height: 840_000 + n,
          current_outpoint: "#{txid}_0",
          name: "Item #{n}",
          content_type: "image/png",
          trace_state: "current"
        },
        attrs
      )
    )
  end

  describe "index" do
    test "lists every known collection, each linking to its page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/collections")

      assert html =~ "Grand Tardinians"
      assert html =~ "Rexxies"
      assert has_element?(view, ~s(a[href="/collections/grand-tardinians"]))
      assert has_element?(view, ~s(a[href="/collections/rexxies"]))
    end

    test "counts come from the index, and an unsynced collection says so", %{conn: conn} do
      item!(OrdinalCollections.known()["grand-tardinians"], 1)
      item!(OrdinalCollections.known()["grand-tardinians"], 2, %{trace_state: "unknown"})

      {:ok, view, _html} = live(conn, ~p"/collections")

      gt = view |> element("#collection-grand-tardinians") |> render()
      assert gt =~ "2 items"
      assert gt =~ "1 of 2 owners traced"

      assert view |> element("#collection-rexxies") |> render() =~ "Not synced yet"
    end

    test "a collection indexed by origin outpoint is listed too", %{conn: conn} do
      cid = "#{String.duplicate("a", 64)}_0"
      item!(cid, 3)

      {:ok, view, _html} = live(conn, ~p"/collections")

      assert has_element?(view, ~s(a[href="/collections/#{cid}"]))
    end

    test "search narrows the list and survives in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")

      html = view |> form("#collection-search", %{"q" => "tardin"}) |> render_change()

      assert_patch(view, ~p"/collections?q=tardin")
      assert html =~ "collection-grand-tardinians"
      refute html =~ "collection-rexxies"
    end

    test "search with no match says so", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/collections?q=nothing-like-this")

      assert html =~ "No collections match"
    end

    test "the source filter narrows by where a collection came from", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections?source=RelayX")

      assert has_element?(view, "#collection-rexxies")
      refute has_element?(view, "#collection-grand-tardinians")
    end

    test "sources are listed, and only verified addresses are links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")

      for name <- ["RelayX", "Twetch", "Rare Candy", "Bubblemint", "Zoide"] do
        assert view |> element("#sources") |> render() =~ name
      end

      assert has_element?(view, ~s(#sources a[href="https://zoide.io/market/collections"]))
      assert has_element?(view, ~s(#sources a[href="https://rarecandy.io"]))
      # A trading-card shop and a parked domain, not the BSV platforms.
      refute has_element?(view, ~s(#sources a[href*="rarecandy.com"]))
      refute has_element?(view, ~s(#sources a[href*="bubblemint.com"]))
      # Did not answer when checked.
      refute has_element?(view, ~s(#sources a[href*="relayx.com"]))
    end
  end

  describe "show" do
    test "lists items with holders, and never reads an untraced item as held", %{conn: conn} do
      cid = OrdinalCollections.known()["grand-tardinians"]
      item!(cid, 1, %{owner: "1HolderXXXXXXXXXXXXXXXXXXXXXXXXXXX"})
      item!(cid, 2, %{trace_state: "untraced"})

      {:ok, _view, html} = live(conn, ~p"/collections/grand-tardinians")

      assert html =~ "Grand Tardinians"
      assert html =~ "Item 1"
      assert html =~ "1HolderXXXXXXXXXXXXXXXXXXXXXXXXXXX"
      assert html =~ "Not traced yet."
      assert html =~ "/content/"
      assert html =~ "Membership is verified"
    end

    test "an untraced item's minter does not read as its holder", %{conn: conn} do
      cid = OrdinalCollections.known()["grand-tardinians"]
      item!(cid, 1, %{owner: "1MinterXXXXXXXXXXXXXXXXXXXXXXXXXXX", trace_state: "untraced"})

      {:ok, _view, html} = live(conn, ~p"/collections/grand-tardinians")

      assert html =~ "Not traced yet."
      refute html =~ "1MinterXXXXXXXXXXXXXXXXXXXXXXXXXXX"
    end

    test "pages through items with a cursor", %{conn: conn} do
      cid = OrdinalCollections.known()["grand-tardinians"]
      for n <- 1..51, do: item!(cid, n)

      {:ok, view, html} = live(conn, ~p"/collections/grand-tardinians")

      assert html =~ "Item 50"
      refute html =~ "Item 51"

      view |> element("#items-next") |> render_click()

      assert has_element?(view, ".collection-item", "Item 51")
      refute has_element?(view, ".collection-item", "Item 50")
    end

    test "an origin outpoint redirects to the collection's own page", %{conn: conn} do
      cid = OrdinalCollections.known()["rexxies"]

      assert {:error, {:live_redirect, %{to: "/collections/rexxies"}}} =
               live(conn, "/collections/#{cid}")
    end

    test "an unknown collection is a 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/collections/not-a-collection") end
    end
  end
end
