defmodule Bitblocks.Repo.Migrations.AddOutputAddressesToTransactions do
  use Ecto.Migration

  # output_addresses stores the P2PKH/P2SH addresses from each output's
  # scriptPubKey, extracted at write time. Enables efficient "find all
  # transactions involving this address" queries via GIN index, replacing
  # any future need to scan the outputs JSON array.
  def up do
    alter table(:transactions) do
      add :output_addresses, {:array, :string}
    end

    create index(:transactions, [:output_addresses], using: :gin)

    # Backfill existing rows by extracting addresses from the stored JSON outputs.
    execute("""
    UPDATE transactions
    SET output_addresses = (
      SELECT array_agg(addr)
      FROM (
        SELECT DISTINCT elem->'scriptPubKey'->'addresses'->0 #>> '{}' AS addr
        FROM jsonb_array_elements(to_jsonb(outputs)) AS elem
        WHERE elem->'scriptPubKey'->'addresses'->0 IS NOT NULL
      ) sub
      WHERE addr IS NOT NULL
    )
    WHERE outputs IS NOT NULL
      AND array_length(outputs, 1) > 0;
    """)
  end

  def down do
    drop index(:transactions, [:output_addresses])

    alter table(:transactions) do
      remove :output_addresses
    end
  end
end
