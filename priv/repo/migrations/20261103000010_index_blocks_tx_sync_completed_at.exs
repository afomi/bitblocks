defmodule Bitblocks.Repo.Migrations.IndexBlocksTxSyncCompletedAt do
  use Ecto.Migration

  # /syncing lists the most recently completed blocks every 30 seconds
  # (Bitblocks.SyncProgress). Without this index that is a sort over every
  # completed block. Partial, since headers that never synced txs have no
  # completion time. Concurrent, so tip sync keeps writing while it builds.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(
      index(
        :blocks,
        [:tx_sync_completed_at],
        where: "tx_sync_completed_at IS NOT NULL",
        concurrently: true
      )
    )
  end
end
