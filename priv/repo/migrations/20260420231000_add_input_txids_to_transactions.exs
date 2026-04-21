defmodule Bitblocks.Repo.Migrations.AddInputTxidsToTransactions do
  use Ecto.Migration

  # input_txids stores the parent txids referenced by each input — extracted
  # from the JSON inputs array at write time. This allows efficient "find
  # transactions that spend this txid" queries using a GIN index, replacing
  # the previous full-table unnest+LIKE scan in tx_graph_live.
  def up do
    alter table(:transactions) do
      add :input_txids, {:array, :string}
    end

    # GIN index enables fast ANY(@txid) membership queries.
    create index(:transactions, [:input_txids], using: :gin)

    # Backfill existing rows by extracting txids from the stored JSON inputs.
    # Skips coinbase inputs (txid all-zeros or missing).
    execute("""
    UPDATE transactions
    SET input_txids = (
      SELECT array_agg(elem->>'txid')
      FROM jsonb_array_elements(
        CASE
          WHEN inputs IS NOT NULL THEN
            to_jsonb(inputs)
          ELSE '[]'::jsonb
        END
      ) AS elem
      WHERE elem->>'txid' IS NOT NULL
        AND elem->>'txid' !~ '^0+$'
    )
    WHERE inputs IS NOT NULL
      AND array_length(inputs, 1) > 0;
    """)
  end

  def down do
    drop index(:transactions, [:input_txids])

    alter table(:transactions) do
      remove :input_txids
    end
  end
end
