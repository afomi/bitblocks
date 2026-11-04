defmodule Bitblocks.Repo.Migrations.AddTalliesToTransactions do
  use Ecto.Migration

  # The tx pipeline's tallies (docs/TX_PIPELINE.md). `total_input_satoshis`
  # and `total_output_satoshis` already exist; these join them.
  #
  #   fee_satoshis    sats in minus sats out; 0 for a coinbase, which pays no
  #                   fee; nil while sats in is unknown (a previous output
  #                   isn't stored). Never guessed.
  #   burned_satoshis sats locked in provably unspendable outputs
  #                   (OP_RETURN or OP_FALSE OP_RETURN); 0 when none.
  #
  # Nullable with no default, so Postgres records the columns in the catalog
  # and rewrites nothing: safe on the ~10M-row table. No index here (AGENTS.md,
  # "Migrations on large tables").
  def change do
    alter table(:transactions) do
      add(:fee_satoshis, :bigint)
      add(:burned_satoshis, :bigint)
    end
  end
end
