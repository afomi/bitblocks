defmodule Bitblocks.Repo.Migrations.CreateSupportBlockScans do
  use Ecto.Migration

  # #74 option 3: blocks above complete_through read once for gifts to the
  # donation address, ahead of the sync (Bitblocks.Support.Scan). One row per
  # block scanned; a small table: blocks since the address existed, and rows
  # below complete_through are no longer read.
  def change do
    create table(:support_block_scans) do
      # The block read, and its hash then: a row whose hash no longer matches
      # the header at its height (a reorg) is read again.
      add(:height, :integer, null: false)
      add(:block_hash, :string, null: false)
      # The address scanned for; a changed bsv_address starts over.
      add(:address, :string, null: false)
      # Sats the block's txs gave the address (Support.Received: change isn't a gift).
      add(:gift_sats, :bigint, null: false, default: 0)
      add(:gift_txids, {:array, :string}, null: false, default: [])
      add(:scanned_at, :utc_datetime, null: false)
    end

    create(unique_index(:support_block_scans, [:address, :height]))
  end
end
