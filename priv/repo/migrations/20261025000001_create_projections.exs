defmodule Bitblocks.Repo.Migrations.CreateProjections do
  use Ecto.Migration

  # Managed projections (#29, docs/MANAGED_SERVICES.md): a tenant's filter
  # over the ingest-time tag columns on `transactions`, served as hydrate /
  # follow / status. One node, one index, many tenants.
  #
  # filter          — JSON: tag column => values. A tx matches when each
  #                   listed column contains every listed value; columns AND.
  # definition_hash — sha256 of the canonical (sorted) filter JSON, so two
  #                   tenants with the same filter share one definition id.
  # status          — backfilling | ready | paused.
  def change do
    create table(:projections) do
      add(:tenant, :string, null: false)
      add(:name, :string, null: false)
      add(:filter, :map, null: false)
      add(:definition_hash, :string, null: false)
      add(:status, :string, null: false, default: "backfilling")

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:projections, [:tenant, :name]))
    create(index(:projections, [:definition_hash]))
  end
end
