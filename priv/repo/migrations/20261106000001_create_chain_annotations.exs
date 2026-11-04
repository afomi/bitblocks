defmodule Bitblocks.Repo.Migrations.CreateChainAnnotations do
  use Ecto.Migration

  # Events placed on the chain by hand: forks, upgrades, halvings, mintings,
  # milestones and real-world events (Bitblocks.Annotations). Admin CRUD at
  # /annotations and /api/v1/annotations; drawn on /chain-scrubber and
  # /tx-graph.
  #
  # An annotation is anchored by any of a height, a txid or a moment in time.
  # resolved_height is where it draws, derived on every save: the stored tx's
  # height for a txid, else the height given, else the first block mined at or
  # after occurred_at. nil means "not on the chain we hold yet" (a tx not
  # synced, a date before genesis or after our tip); Annotations.resolve_all/0
  # tries again.
  #
  # A small table: tens to thousands of rows, read whole.
  def change do
    create table(:chain_annotations) do
      # fork | upgrade | halving | milestone | mint | world | note
      add(:kind, :string, null: false)
      add(:title, :string, null: false)
      add(:body, :text)
      # Where the claim comes from: a spec, an article, a tx page.
      add(:source_url, :string)

      # Anchors; at least one is set (checked in the changeset).
      add(:height, :integer)
      add(:txid, :string, size: 64)
      add(:occurred_at, :utc_datetime)

      add(:resolved_height, :integer)
      # How resolved_height was found: txid | height | time.
      add(:resolved_by, :string)

      timestamps(type: :utc_datetime)
    end

    create(index(:chain_annotations, [:resolved_height]))
    create(index(:chain_annotations, [:kind]))
  end
end
