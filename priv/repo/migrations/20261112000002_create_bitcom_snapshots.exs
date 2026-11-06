defmodule Bitblocks.Repo.Migrations.CreateBitcomSnapshots do
  use Ecto.Migration

  # Versioned, hashed copies of the Bitcom registry export (#21). A new table:
  # the container's disk does not survive a deploy, so the bytes live here.
  def change do
    create table(:bitcom_snapshots) do
      # sha256 of `body`, hex. A snapshot is written only when this changes.
      add(:sha256, :string, null: false)
      # The canonical JSON, byte for byte: what the hash covers and what the
      # API serves, so a reader can check one against the other.
      add(:body, :text, null: false)
      add(:namespaces, :integer, null: false)
      # The tx that anchors `sha256` on chain, once one exists.
      add(:anchor_txid, :string)

      timestamps(updated_at: false)
    end

    create(unique_index(:bitcom_snapshots, [:sha256]))
  end
end
