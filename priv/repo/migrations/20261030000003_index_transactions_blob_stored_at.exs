defmodule Bitblocks.Repo.Migrations.IndexTransactionsBlobStoredAt do
  use Ecto.Migration

  # TxStore.verify_sample/1 and Release.store_collection_blobs/1 count and
  # sample stored rows; without an index both scan all of `transactions`
  # (~10M rows, 52 GB), and the check timed out on prod (infra, 2026-10-30).
  # Partial, so it holds only stored rows and stays tiny. Concurrent, per #28.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(
      index(:transactions, [:blob_stored_at],
        where: "blob_stored_at IS NOT NULL",
        concurrently: true
      )
    )
  end
end
