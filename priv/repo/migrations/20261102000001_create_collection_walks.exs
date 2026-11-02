defmodule Bitblocks.Repo.Migrations.CreateCollectionWalks do
  use Ecto.Migration

  # A finished walk of a collection's mint chain (#37). A row means the walk
  # reached the end of every link from the bytes and the spend answers, with
  # no lookup failing, so an outpoint outside the index can be answered
  # `member: false`. A later walk that can't finish removes the row.
  #
  # collection_id — the collection's origin outpoint (txid_vout).
  # finished_at   — when the walk ended; the `false` answer is as of this time,
  #                 since a later mint can extend the chain.
  # mints, items  — what that walk found.
  def change do
    create table(:collection_walks) do
      add(:collection_id, :string, null: false)
      add(:finished_at, :utc_datetime, null: false)
      add(:mints, :integer, null: false)
      add(:items, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:collection_walks, [:collection_id]))
  end
end
