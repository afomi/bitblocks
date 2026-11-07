defmodule BitblocksWeb.SitemapController do
  @moduledoc """
  Serves `/sitemap.xml` for search engines.

  Lists only the public, indexable pages from the router's browser scope.
  Operator routes behind `:admin` and the chain data (blocks, txs, tokens,
  searches over them) are deliberately left out, and `robots.txt` keeps
  indexers off them.
  """
  use BitblocksWeb, :controller

  @public_paths [
    {"/", "daily", "1.0"},
    {"/reorgs", "daily", "0.6"},
    {"/tokens", "daily", "0.7"},
    {"/protocols", "weekly", "0.6"},
    {"/bitcom", "daily", "0.6"},
    {"/guide", "monthly", "0.6"},
    {"/start", "weekly", "0.7"},
    {"/start/api", "monthly", "0.6"},
    {"/start/guidance", "monthly", "0.5"},
    {"/start/interop", "monthly", "0.5"},
    {"/about", "monthly", "0.5"},
    {"/pricing", "monthly", "0.5"},
    {"/apps", "monthly", "0.5"},
    {"/resources", "monthly", "0.5"},
    {"/did", "monthly", "0.4"},
    {"/collections", "weekly", "0.5"},
    {"/collections/grand-tardinians", "weekly", "0.3"},
    {"/collections/rexxies", "monthly", "0.3"},
    {"/types", "weekly", "0.6"}
  ]

  # One page per transaction type (the glossary, #49).
  @public_paths @public_paths ++
                  Enum.map(Bitblocks.TxTypes.ids(), &{"/types/#{&1}", "weekly", "0.4"})

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
