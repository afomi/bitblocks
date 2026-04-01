defmodule BitblocksWeb.Seo do
  @moduledoc false

  @default_description "Explore Bitcoin SV blocks, transactions, protocols, and network status with Bitblocks."
  @default_social_image "https://bitblocks.app/images/og-image.jpg"
  @default_social_image_alt "Bitblocks Bitcoin SV blockchain explorer preview"

  def public_page(attrs \\ []) do
    attrs = Map.new(attrs)

    %{
      page_title: Map.get(attrs, :page_title, "Bitblocks"),
      meta_description: Map.get(attrs, :meta_description, @default_description),
      canonical_path: Map.get(attrs, :canonical_path, "/"),
      meta_robots: Map.get(attrs, :meta_robots, "index, follow"),
      social_image: Map.get(attrs, :social_image, @default_social_image),
      social_image_alt: Map.get(attrs, :social_image_alt, @default_social_image_alt)
    }
  end
end
