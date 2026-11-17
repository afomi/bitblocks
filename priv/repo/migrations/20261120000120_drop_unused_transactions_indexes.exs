defmodule Bitblocks.Repo.Migrations.DropUnusedTransactionsIndexes do
  use Ecto.Migration

  # Six single-column indexes on `transactions` that nothing reads (#92):
  # prod's Q2 in docs/STORAGE_PLAN.md found each with 0 scans, about 5.5 GB
  # together. Every non-HOT update writes to every index on the table, so
  # 21 down to 15 makes each such update about 30% cheaper (#88).
  # `transactions_output_script_hashes_index` and `transactions_aip_signers_index`
  # stay, as the plan says.
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
    script_analysis_version: "transactions_script_analysis_version_index",
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
