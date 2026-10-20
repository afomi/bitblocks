defmodule BitblocksWeb.SitemapController do
  @moduledoc """
  Serves `/sitemap.xml` for search engines.

  Lists only the public, indexable pages from the router's browser scope.
  Operator routes behind `:admin` and per-record pages (blocks, txs, tokens)
  are deliberately left out.
  """
  use BitblocksWeb, :controller

  @public_paths [
    {"/", "daily", "1.0"},
    {"/blocks", "always", "0.9"},
    {"/search", "monthly", "0.8"},
    {"/status", "hourly", "0.7"},
    {"/tokens", "daily", "0.7"},
    {"/order-book", "daily", "0.7"},
    {"/protocols", "weekly", "0.6"},
    {"/bitcom", "daily", "0.6"},
    {"/metanet", "weekly", "0.6"},
    {"/guide", "monthly", "0.6"},
    {"/about", "monthly", "0.5"},
    {"/pricing", "monthly", "0.5"},
    {"/apps", "monthly", "0.5"},
    {"/resources", "monthly", "0.5"},
    {"/did", "monthly", "0.4"},
    {"/wall", "daily", "0.4"},
    {"/reward_wall", "daily", "0.4"},
    {"/collections/rexxies", "monthly", "0.3"}
  ]

  @doc "The public paths listed in the sitemap."
  def public_paths, do: Enum.map(@public_paths, &elem(&1, 0))

  def index(conn, _params) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, sitemap_xml(BitblocksWeb.Endpoint.url()))
  end

  defp sitemap_xml(base_url) do
    urls =
      Enum.map_join(@public_paths, "\n", fn {path, changefreq, priority} ->
        """
          <url>
            <loc>#{base_url}#{path}</loc>
            <changefreq>#{changefreq}</changefreq>
            <priority>#{priority}</priority>
          </url>\
        """
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{urls}
    </urlset>
    """
  end
end
