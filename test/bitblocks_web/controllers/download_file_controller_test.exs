defmodule BitblocksWeb.DownloadFileControllerTest do
  # A paid download's manifest and links (https://github.com/afomi/bitblocks/issues/111):
  # for the buyer's session or the script's token only, never through a node
  # (each link is a signed store URL), and closed once refunded.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.DownloadsFixtures

  alias Bitblocks.Downloads.{Purchase, Purchases}
  alias Bitblocks.Repo
  alias BitblocksWeb.DownloadFileController

  @bodies ["first block", "second block", "third block"]

  setup do
    with_price()
    with_checkout_configured()
    stub_checkout(self())
    stored_chain(@bodies)
    user = user!()

    {:ok, p} =
      Purchases.create(user, %{"from" => "0", "to" => "2", "data" => "raw", "format" => "bin"})

    {:ok, _} = Purchases.start_checkout(p, "https://example.test")
    p = Repo.get!(Purchase, p.id)

    {:ok, "paid"} =
      Purchases.handle_event(event("checkout.session.completed", completed_session(p)))

    {:ok, :ready} = Purchases.prepare(Repo.get!(Purchase, p.id))

    {:ok, user: user, purchase: Repo.get!(Purchase, p.id)}
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  test "the script's token gets the next batch of links, each with its sha256", %{
    conn: conn,
    purchase: p
  } do
    token = DownloadFileController.token(p.id)
    conn = get(conn, "/downloads/#{p.id}/links.tsv?from=1&token=#{token}")

    assert response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    lines = conn.resp_body |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\t"))
    assert Enum.map(lines, &hd/1) == ["1", "2"]

    for {[_height, _hash, bytes, sum, name, url], body} <- Enum.zip(lines, Enum.drop(@bodies, 1)) do
      assert bytes == Integer.to_string(byte_size(body))
      assert sum == sha(body)
      assert String.ends_with?(name, ".bin")
      assert url =~ "expires="
    end

    # Past the last block: an empty body, which ends the script's loop.
    assert response(get(build_conn(), "/downloads/#{p.id}/links.tsv?from=3&token=#{token}"), 200) ==
             ""
  end

  test "the manifest is the pinned bytes, for the buyer's session", %{
    conn: conn,
    user: user,
    purchase: p
  } do
    conn =
      conn
      |> init_test_session(%{"user_id" => user.id})
      |> get("/downloads/#{p.id}/manifest.json")

    assert response(conn, 200)
    assert get_resp_header(conn, "x-manifest-sha256") == [p.manifest_sha256]
    assert sha(conn.resp_body) == p.manifest_sha256
    assert %{"files" => [_, _, _]} = Jason.decode!(conn.resp_body)
  end

  test "anyone else gets a 404, which says nothing", %{conn: conn, purchase: p} do
    other = user!()

    assert response(get(conn, "/downloads/#{p.id}/links.tsv"), 404)
    assert response(get(build_conn(), "/downloads/#{p.id}/links.tsv?token=nonsense"), 404)

    assert response(
             build_conn()
             |> init_test_session(%{"user_id" => other.id})
             |> get("/downloads/#{p.id}/manifest.json"),
             404
           )

    other_token = DownloadFileController.token(Ecto.UUID.generate())
    assert response(get(build_conn(), "/downloads/#{p.id}/links.tsv?token=#{other_token}"), 404)
  end

  test "after a refund, no links are issued", %{conn: conn, purchase: p} do
    {:ok, "refunded"} =
      Purchases.handle_event(
        event("charge.refunded", %{"payment_intent" => p.stripe_payment_intent})
      )

    token = DownloadFileController.token(p.id)
    conn = get(conn, "/downloads/#{p.id}/links.tsv?token=#{token}")
    assert response(conn, 410) =~ "can't be downloaded now"
  end
end
