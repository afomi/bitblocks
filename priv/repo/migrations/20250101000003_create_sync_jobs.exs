defmodule Bitblocks.Repo.Migrations.CreateSyncJobs do
  use Ecto.Migration

  def change do
    create table(:sync_jobs) do
      add :scope, :string, null: false
      add :start_block, :integer, null: false
      add :end_block, :integer, null: false
      add :status, :string, null: false
      add :blocks_synced, :integer, default: 0
      add :total_blocks, :integer
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :errors_count, :integer, default: 0

      timestamps()
    end

    create index(:sync_jobs, [:status])
    create index(:sync_jobs, [:started_at])
  end
end
