defmodule Bitblocks.Repo.Migrations.DropUnusedTransactionsIndexes do
  use Ecto.Migration

  # Five single-column indexes on `transactions` that nothing reads (#92):
  # prod's Q2 in docs/STORAGE_PLAN.md found each with 0 scans, and infra
  # dropped them by hand on 2026-11-17 (about 6.7 GB), so on prod this is a
  # no-op. Every non-HOT update writes to every index on the table.
  # `transactions_script_analysis_version_index` stays: the script_analysis
  # backfill scanned it 392 times on 2026-11-17. So do
  # `transactions_output_script_hashes_index` and `transactions_aip_signers_index`,
  # as the plan says.
  #
  # Concurrent, as every index change on this table (#28): DROP INDEX
  # CONCURRENTLY can't run in a transaction, and IF EXISTS lets infra drop them
  # by hand first under these same names.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @indexes [
    total_output_satoshis: "transactions_total_output_satoshis_index",
    total_input_satoshis: "transactions_total_input_satoshis_index",
    inserted_at: "transactions_inserted_at_index",
    output_count: "transactions_output_count_index",
    input_count: "transactions_input_count_index"
  ]

  def up do
    for {_column, name} <- @indexes do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
    end
  end

  def down do
    for {column, name} <- @indexes do
      create_if_not_exists(index(:transactions, [column], name: name, concurrently: true))
    end
  end
end
