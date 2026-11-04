defmodule Bitblocks.Repo.Migrations.AddRawLocationToTransactions do
  use Ecto.Migration

  # Where a tx's bytes sit in its block's object in the tx store
  # (docs/TX_STORAGE.md, step 1): `blocks/<height>-<hash>.bin`, read by range.
  #
  #   raw_offset  byte offset of the tx within the block's serialized bytes
  #   raw_length  the tx's byte length
  #
  # Both nil until the block object is written and verified
  # (blocks.raw_object_stored_at). Nullable with no default, so Postgres
  # records the columns in the catalog and rewrites nothing: safe on the
  # 11M-row table. No index: rows are found by txid, never by offset.
  #
  # The ALTER still takes a brief ACCESS EXCLUSIVE lock; lock_timeout makes it
  # fail fast (and the deploy retry) rather than queue every tx write behind a
  # long-running read.
  def change do
    execute("SET LOCAL lock_timeout = '10s'", "")

    alter table(:transactions) do
      add(:raw_offset, :bigint)
      add(:raw_length, :bigint)
    end
  end
end
