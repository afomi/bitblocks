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
    panel = view |> element("#rexxie-holder") |> render()
    assert panel =~ "Membership verified."
    assert panel =~ "Held by 1HolderXXXXXXXXXXXXXXXXXXXXXXXXXXX."
  end

  test "an unknown holder reads as words, not a state name", %{conn: conn} do
    Bitblocks.Repo.insert!(%Item{
      collection_id: Bitblocks.OrdinalCollections.known()["rexxies"],
      origin: "#{@mint}_3",
      mint_txid: @mint,
      trace_state: "unknown",
      trace_reason: "whatsonchain: {:error, :timeout}"
    })

    {:ok, view, _html} = live(conn, ~p"/collections/rexxies")
    render_click(view, "select_nft", %{"number" => "1"})

    panel = view |> element("#rexxie-holder") |> render()
    assert panel =~ "Membership verified."
    assert panel =~ "Owner unknown: WhatsOnChain did not answer."
    refute panel =~ ":timeout"
  end

  test "the breadcrumb links back to the collections index", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/collections/rexxies")

    assert has_element?(view, ~s(#rexxies-breadcrumb a[href="/collections"]))
  end

  test "without an indexed holding the panel shows no holder row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/collections/rexxies")
    render_click(view, "select_nft", %{"number" => "1"})

    refute has_element?(view, "#rexxie-holder")
  end

  test "a Rexxie image URL from the collection page returns catalog bytes", %{conn: conn} do
    page = get(conn, ~p"/collections/rexxies")
    html = html_response(page, 200)

    assert html =~ "Showing"
    assert html =~ "Rexxie #"

    [src] =
      Regex.run(
        ~r/src="(\/images\/rexxies\/\d+\.png)"/,
        html,
        capture: :all_but_first
      )

    dir = Bitblocks.Rexxies.images_dir()
    refute dir =~ "rexxie-indexer"

    fixture =
      File.read!(
        Path.expand(
          "../../fixtures/rexxie_images/pixel.png",
          __DIR__
        )
      )

    dest = Path.join(dir, Path.basename(src))
    File.mkdir_p!(dir)
    File.write!(dest, fixture)
    on_exit(fn -> File.rm(dest) end)

    image = get(build_conn(), src)

    assert image.status == 200
    [content_type] = get_resp_header(image, "content-type")
    assert content_type =~ "image/"
    assert image.resp_body == fixture

    proof =
      "status=#{image.status} content-type=#{content_type} bytes=#{Base.encode16(image.resp_body)}\n"

    proof_path = Path.expand("tmp/rexxie-image-proof.txt")
    File.mkdir_p!(Path.dirname(proof_path))
    File.write!(proof_path, proof)
    assert File.read!(proof_path) == proof
  end
end
