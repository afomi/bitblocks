defmodule Bitblocks.Repo.Migrations.IndexTransactionsBProtocolId do
  use Ecto.Migration

  # The txs tagged B:// in id order (#18, #25): `/files` and a B:// namespace
  # on `/bitcom` read the newest of them, walking this small partial index
  # backwards rather than the GIN index on `protocols` plus a sort.
  # The queries spell the predicate exactly as below
  # (`Bitblocks.Bitcom.Files.b_tagged/1`), so the planner can prove it.
  # Concurrent, as every index on this table (#28).
  #
  # On prod the build reads all of `transactions`, which can outlast a deploy,
  # so infra may build it by hand first, under this same name:
  #
  #   CREATE INDEX CONCURRENTLY IF NOT EXISTS transactions_b_protocol_id_index
  #     ON transactions (id) WHERE protocols @> ARRAY['B://']::varchar[];
  #
  # Then this migration finds it and only checks it. A build that stopped
  # partway leaves an INVALID index of this name, which IF NOT EXISTS would
  # skip silently, so the migration fails loudly on one: drop it
  # (DROP INDEX CONCURRENTLY transactions_b_protocol_id_index) and run it again.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "transactions_b_protocol_id_index"

  def up do
    create_if_not_exists(
      index(:transactions, [:id],
        name: @name,
        where: "protocols @> ARRAY['B://']::varchar[]",
        concurrently: true
      )
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
    drop_if_exists(index(:transactions, [:id], name: @name, concurrently: true))
  end
end
