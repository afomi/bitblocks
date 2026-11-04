defmodule Bitblocks.Repo.Migrations.AddPausedToSyncSettings do
  @moduledoc """
  A durable pause for the sync loop (#44): while `paused`, the coordinator
  dispatches no new block jobs; blocks already dispatched finish. Persisted
  so a restart, a deploy or a new leader keeps it.
  """
  use Ecto.Migration

  def change do
    alter table(:sync_settings) do
      # Set on /sync (`Bitblocks.Sync.set_paused/1`); read by the coordinator
      # before every dispatch.
      add(:paused, :boolean, null: false, default: false)
    end
  end
end
