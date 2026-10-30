defmodule Bitblocks.Repo.Migrations.AddBlobStoredAtAndTrails do
  use Ecto.Migration

  # Blob store for raw tx bytes (Bitblocks.TxStore).
  #
  # transactions.blob_stored_at — when the tx's bytes were written to the blob
  #   store (s3://…/raw/{txid}) and read back verified. Null means "not in the
  #   blob store"; the API only advertises a CDN URL when it's set. A nullable
  #   column without a default is a metadata-only change: no table rewrite,
  #   safe on the multi-GB table (#28). No index: it isn't queried by value yet.
  #
  # collection_items.trail — txids the item moved through, oldest first, as
  #   traced (provenance, and the exact set of txs to keep in the blob store).
  def change do
    alter table(:transactions) do
      add(:blob_stored_at, :utc_datetime)
    end

    alter table(:collection_items) do
      add(:trail, {:array, :string}, null: false, default: [])
    end
  end
end
