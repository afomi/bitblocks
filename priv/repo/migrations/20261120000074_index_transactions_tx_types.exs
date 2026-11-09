defmodule Bitblocks.Repo.Migrations.IndexTransactionsTxTypes do
  use Ecto.Migration

  # `GET /api/v1/txs?type=` (#49): the txs whose `tx_types` hold a type id,
  # by `@>` on a GIN index. Concurrent, as every index on this table (#28).
  #
  # On prod the build reads all of `transactions`, which can outlast a deploy,
  # so infra may build it by hand first, under this same name:
  #
  #   CREATE INDEX CONCURRENTLY IF NOT EXISTS transactions_tx_types_index
  #     ON transactions USING GIN (tx_types);
  #
  # Then this migration finds it and only checks it. A build that stopped
  # partway leaves an INVALID index of this name, which IF NOT EXISTS would
  # skip silently, so the migration fails loudly on one: drop it
  # (DROP INDEX CONCURRENTLY transactions_tx_types_index) and run it again.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "transactions_tx_types_index"

  def up do
    create_if_not_exists(
      index(:transactions, [:tx_types], name: @name, using: "GIN", concurrently: true)
    )

    flush()

    case repo().query!(
           "SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)",
           [@name]
         ) do
      %{rows: [[true]]} -> :ok
      other -> raise "#{@name} is not a valid index (#{inspect(other.rows)}); drop it and rerun"
    end
  end

  def down do
    drop_if_exists(index(:transactions, [:tx_types], name: @name, concurrently: true))
  end
end
