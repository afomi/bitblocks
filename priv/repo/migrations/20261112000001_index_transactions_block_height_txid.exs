defmodule Bitblocks.Repo.Migrations.IndexTransactionsBlockHeightTxid do
  use Ecto.Migration

  # The confirmation-order keyset for `GET /api/v1/txs` and protocol feeds
  # (#35), and `(block_height, txid)` hydrate: ORDER BY and the row comparison
  # both come straight off this index, in either direction, with no sort of
  # the rows in a block. Concurrent, as every index on this table (#28).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(index(:transactions, [:block_height, :txid], concurrently: true))
  end
end
