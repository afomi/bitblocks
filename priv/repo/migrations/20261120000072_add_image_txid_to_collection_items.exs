defmodule Bitblocks.Repo.Migrations.AddImageTxidToCollectionItems do
  use Ecto.Migration

  # collection_items.image_txid — the tx whose B:// file is the item's image,
  # read from the mint's bytes: a Rare Candy item's metadata names it
  # (`"image": "b://<txid>"`), and an unencrypted RelayX mint carries its image
  # as a B:// output of the mint itself. Served at /b/<txid>. Nil when the
  # chain names no image (1Sat items are their own inscription; Rexxies come
  # from the catalog).
  def change do
    alter table(:collection_items) do
      add(:image_txid, :string)
    end
  end
end
