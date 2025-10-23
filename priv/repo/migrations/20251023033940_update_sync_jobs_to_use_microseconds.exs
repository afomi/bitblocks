defmodule Bitblocks.Repo.Migrations.UpdateSyncJobsToUseMicroseconds do
  use Ecto.Migration

  def change do
    alter table(:sync_jobs) do
      modify :started_at, :utc_datetime_usec, null: false
      modify :completed_at, :utc_datetime_usec
    end
  end
end
