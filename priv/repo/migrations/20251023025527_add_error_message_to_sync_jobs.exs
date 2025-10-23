defmodule Bitblocks.Repo.Migrations.AddErrorMessageToSyncJobs do
  use Ecto.Migration

  def change do
    alter table(:sync_jobs) do
      add :error_message, :text
    end
  end
end
