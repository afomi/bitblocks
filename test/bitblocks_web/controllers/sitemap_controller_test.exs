defmodule BitblocksWeb.SitemapControllerTest do
  use BitblocksWeb.ConnCase, async: false

  alias BitblocksWeb.SitemapController

  test "GET /sitemap.xml lists public pages as XML", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")

    assert response_content_type(conn, :xml)
    body = response(conn, 200)
    assert body =~ ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)

    for path <- SitemapController.public_paths() do
      assert body =~ "<loc>#{BitblocksWeb.Endpoint.url()}#{path}</loc>"
    end
  end

  test "GET /sitemap.xml leaves out the operator surface", %{conn: conn} do
    body = conn |> get(~p"/sitemap.xml") |> response(200)

    for path <- ~w(/sync /admin /config /debug /graph /highlights /transactions) do
      refute body =~ "#{BitblocksWeb.Endpoint.url()}#{path}<"
    end
  end

  test "every sitemap path is served publicly", %{conn: conn} do
    Application.put_env(:bitblocks, :admin_auth, enabled: true)
    on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, enabled: false) end)

    for path <- SitemapController.public_paths() do
      conn = get(build_conn(), path)
      assert conn.status in [200, 302], "#{path} returned #{conn.status}"
    end
  end

  test "robots.txt points at the sitemap" do
    robots = File.read!(Application.app_dir(:bitblocks, "priv/static/robots.txt"))
    assert robots =~ "Sitemap: https://bitblocks.app/sitemap.xml"
  end
end
