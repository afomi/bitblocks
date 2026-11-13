defmodule Bitblocks.Repo.Migrations.AddTraceVersionToCollectionItems do
  use Ecto.Migration

  # The trace race (#73): a reorg rewind that marks an item bumps this, and a
  # trace writes only if it still holds the version it read, so a trace already
  # running when the item was marked can't overwrite the mark.
  def change do
    alter table(:collection_items) do
      add(:trace_version, :integer, null: false, default: 0)
    end
  end
end
