defmodule BitblocksWeb.CollectionLiveTest do
  # The LiveView process has to see rows inserted by the test.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.OrdinalFixtures
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
    test "the standard pill links to the standard's type page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections/grand-tardinians")
      assert has_element?(view, ~s(a#collection-standard[href="/types/1sat-inscription"]), "1Sat")

      {:ok, view, _html} = live(conn, ~p"/collections/rexxies")
      assert has_element?(view, ~s(a#collection-standard[href="/types/run"]), "Run")
    end

    test "lists items and states what's proven", %{conn: conn} do
      cid = OrdinalCollections.known()["grand-tardinians"]
      item = item!(cid, 1, %{owner: "1HolderXXXXXXXXXXXXXXXXXXXXXXXXXXX"})

      {:ok, view, html} = live(conn, ~p"/collections/grand-tardinians")

      assert html =~ "Grand Tardinians"
      assert html =~ "Item 1"
      assert html =~ "/content/#{item.origin}"
      assert html =~ "Membership is verified"

      panel = view |> element("#item-#{item.id}") |> render_click()
      assert panel =~ "Held by 1HolderXXXXXXXXXXXXXXXXXXXXXXXXXXX."
    end

    test "an untraced item's minter does not read as its holder", %{conn: conn} do
      cid = OrdinalCollections.known()["grand-tardinians"]

      item =
        item!(cid, 1, %{owner: "1MinterXXXXXXXXXXXXXXXXXXXXXXXXXXX", trace_state: "untraced"})

      {:ok, view, _html} = live(conn, ~p"/collections/grand-tardinians")
      panel = view |> element("#item-#{item.id}") |> render_click()

      assert panel =~ "Not traced yet."
      refute panel =~ "1MinterXXXXXXXXXXXXXXXXXXXXXXXXXXX"
    end

    test "a layered item stacks its layers, grid and detail", %{conn: conn} do
      cid = OrdinalCollections.known()["grand-tardinians"]
      {bottom, top} = {"#{String.duplicate("1", 64)}_0", "#{String.duplicate("2", 64)}_0"}

      svg =
        ~s(<svg width="100%" xmlns="http://www.w3.org/2000/svg">) <>
          ~s(<image href="/content/#{bottom}" width="100%" /><image href="/content/#{top}" />) <>
          "</svg>"

      output = item(cid, "Layered", address(), [], svg)
      {mint, _hex} = minted = tx([funding_outpoint()], [contract(), output])
      publish(minted, 840_001)
      OrdinalCollections.import_txs([mint])

      layered =
        item!(cid, 1, %{
          origin: "#{mint}_1",
          mint_txid: mint,
          content_type: "image/svg+xml",
          name: "Layered"
        })

      {:ok, view, _html} = live(conn, ~p"/collections/grand-tardinians")

      grid = view |> element("#item-#{layered.id}") |> render()
      assert grid =~ ~s(src="/content/#{bottom}")
      assert grid =~ ~s(src="/content/#{top}")
      refute grid =~ ~s(src="/content/#{mint}_1")

      view |> element("#item-#{layered.id}") |> render_click()
      assert has_element?(view, ~s(#item-detail img[src="/content/#{top}"]))
    end

    test "only an SVG that does nothing but stack inscriptions is layered" do
      layer = ~s(<image href="/content/#{String.duplicate("a", 64)}_0" />)

      assert OrdinalCollections.svg_layers("<svg>#{layer}</svg>") ==
               ["/content/#{String.duplicate("a", 64)}_0"]

      for svg <- [
            "<svg/>",
            "<svg>#{layer}<script>alert(1)</script></svg>",
            ~s(<svg><image href="https://evil.example/x.png" /></svg>),
            <<0xFF, 0xFE>>
          ] do
        assert OrdinalCollections.svg_layers(svg) == []
      end
    end

    test "pages through items, keeping the page in the URL", %{conn: conn} do
      cid = OrdinalCollections.known()["grand-tardinians"]
      for n <- 1..51, do: item!(cid, n)

      {:ok, view, html} = live(conn, ~p"/collections/grand-tardinians")

      assert html =~ "Item 50"
      refute html =~ "Item 51"

      view |> element("#items-next") |> render_click()

      assert_patch(view, ~p"/collections/grand-tardinians?page=2")
      assert has_element?(view, ".collection-item", "Item 51")
      refute has_element?(view, ".collection-item", "Item 50")
    end

    test "search matches a name or a trait value", %{conn: conn} do
      cid = OrdinalCollections.known()["grand-tardinians"]
      item!(cid, 1, %{traits: [%{"name" => "Eyes", "value" => "Reptilian"}]})
      item!(cid, 2)

      {:ok, view, _html} = live(conn, ~p"/collections/grand-tardinians")

      view |> form("#item-search", %{"q" => "reptil"}) |> render_submit()

      assert_patch(view, ~p"/collections/grand-tardinians?q=reptil")
      assert has_element?(view, ".collection-item", "Item 1")
      refute has_element?(view, ".collection-item", "Item 2")
    end

    test "a percent sign in a search is literal", %{conn: conn} do
      item!(OrdinalCollections.known()["grand-tardinians"], 1)

      {:ok, _view, html} = live(conn, ~p"/collections/grand-tardinians?q=%25")

      assert html =~ "No items found"
    end

    test "the same layout serves every collection, with its trait filter", %{conn: conn} do
      trait = %{"name" => "Eyes", "value" => "Reptilian"}

      for {slug, n} <- [{"grand-tardinians", 1}, {"rexxies", 2}] do
        cid = OrdinalCollections.known()[slug]
        item = item!(cid, n, %{traits: [trait]})
        item!(cid, n + 10)

        {:ok, view, _html} = live(conn, ~p"/collections/#{slug}")

        assert has_element?(view, "#collection-breadcrumb")
        assert has_element?(view, "#item-search")

        view |> element("#item-#{item.id}") |> render_click()
        view |> element("#item-detail a", "Reptilian") |> render_click()

        assert has_element?(view, ".collection-item", "Item #{n}")
        refute has_element?(view, ".collection-item", "Item #{n + 10}")
      end
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
