defmodule Bitblocks.Repo.Migrations.CreateReorgs do
  use Ecto.Migration

  # Annotations of chain reorganizations this index has seen (#34 phase 1).
  # A later phase rewinds derived rows. This table only records the event.
  def change do
    create table(:reorgs) do
      add(:detected_at, :utc_datetime, null: false)
      add(:last_seen_at, :utc_datetime, null: false)
      add(:fork_height, :integer, null: false)
      add(:fork_point, :integer)
      add(:orphan_count, :integer)
      add(:outcome, :string, null: false)
      add(:summary, :text, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:reorgs, [:fork_height]))
    create(index(:reorgs, [:detected_at]))
  end
end
