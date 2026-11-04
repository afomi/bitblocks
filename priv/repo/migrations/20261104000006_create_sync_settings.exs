defmodule Bitblocks.Repo.Migrations.CreateSyncSettings do
  @moduledoc """
  One row of operator settings for the sync loop, so a choice made on /sync
  survives a restart. Today it holds only the concurrency: how many blocks
  the coordinator works at once (`Bitblocks.Sync.set_concurrency/1`).
  """
  use Ecto.Migration

  def change do
    create table(:sync_settings) do
      # Blocks worked at once, cluster-wide. Clamped on write and on read to
      # the computed limit (cores, database pool, node RPC threads).
      add(:concurrency, :integer, null: false)

      timestamps()
    end
  end
end
