defmodule Bitblocks.Repo.Migrations.AddRawObjectStoredAtToBlocks do
  use Ecto.Migration

  # When the block's exact bytes were written to the tx store as one object
  # (`blocks/<height>-<hash>.bin`) and read back and verified: size, and the
  # first 80 bytes hash to the block hash. nil until then, and always nil for
  # blocks over 32 MB, which take the per-tx path (docs/TX_STORAGE.md).
  # Nullable with no default: a catalog-only change.
  def change do
    alter table(:blocks) do
      add(:raw_object_stored_at, :utc_datetime)
    end
  end
end
