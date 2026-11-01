defmodule BitblocksWeb.Plugs.RexxieImages do
  @moduledoc """
  Serves `/images/rexxies/*.png` from `Bitblocks.Rexxies.images_dir/0`.

  The directory is resolved on each request, so a release can set
  `REXXIE_IMAGES_DIR` without a developer checkout of rexxie-indexer.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["images", "rexxies" | _]} = conn, _opts) do
    Plug.Static.call(conn, static_opts())
  end

  def call(conn, _opts), do: conn

  defp static_opts do
    Plug.Static.init(
      at: "/images/rexxies",
      from: Bitblocks.Rexxies.images_dir(),
      gzip: false,
      cache_control_for_etags: "public, max-age=86400"
    )
  end
end
