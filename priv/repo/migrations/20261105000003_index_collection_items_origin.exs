defmodule Bitblocks.Repo.Migrations.IndexCollectionItemsOrigin do
  use Ecto.Migration

  # `Chain.nft_facts/1` looks an item up by origin outpoint across every
  # collection. The unique index leads with collection_id, so it can't serve
  # that. `collection_items` holds thousands of rows, so a plain build is quick.
  def change do
    create(index(:collection_items, [:origin]))
  end
end
