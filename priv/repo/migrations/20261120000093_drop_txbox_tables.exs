defmodule Bitblocks.Repo.Migrations.DropTxboxTables do
  # Bitblocks is the read side and doesn't broadcast, so the Txbox/mAPI
  # outbound stack is gone. Nothing ever wrote these tables: the only writer,
  # Bitblocks.Outbound, had no callers.
  use Ecto.Migration

  def up do
    drop_if_exists(table(:txbox_mapi_responses))
    drop_if_exists(table(:txbox_txns))
    execute("DROP FUNCTION IF EXISTS txbox_search_vector_trigger()")
  end

  def down do
    raise Ecto.MigrationError,
          "the Txbox tables are gone for good; restore them from 20250101000005 if ever needed"
  end
end
