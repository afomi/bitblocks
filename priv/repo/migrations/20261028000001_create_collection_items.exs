defmodule Bitblocks.Repo.Migrations.CreateCollectionItems do
  use Ecto.Migration

  # 1Sat ordinal collection items (#30): Grand Tardinians first.
  #
  # collection_id    — the collection inscription's origin outpoint (txid_vout).
  # origin           — the item inscription's outpoint at mint (txid_vout).
  # mint_txid        — the tx that minted it; proven a member only when it spends
  #                    the collection's mint-contract chain (see
  #                    Bitblocks.OrdinalCollections), so a fake that merely
  #                    claims the collectionId in its MAP is never an item.
  # current_outpoint — where the item's sat sits now, by tracing spends.
  # owner            — P2PKH address locking current_outpoint, or null when it
  #                    is held by a contract (e.g. listed for sale).
  # trace_state      — current | unknown | untraced; trace_reason says why it
  #                    isn't current. traced_at + trace_source date the answer.
  def change do
    create table(:collection_items) do
      add(:collection_id, :string, null: false)
      add(:origin, :string, null: false)
      add(:mint_txid, :string, null: false)
      add(:mint_height, :integer)
      add(:name, :string)
      add(:content_type, :string)
      add(:traits, {:array, :map}, null: false, default: [])
      add(:current_outpoint, :string)
      add(:owner, :string)
      add(:trace_state, :string, null: false, default: "untraced")
      add(:trace_reason, :string)
      add(:trace_source, :string)
      add(:traced_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:collection_items, [:collection_id, :origin]))
    create(index(:collection_items, [:collection_id, :mint_height, :origin]))
    create(index(:collection_items, [:current_outpoint]))
    create(index(:collection_items, [:owner]))
  end
end
