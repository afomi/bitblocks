defmodule Bitblocks.Repo.Migrations.AddTxTypes do
  use Ecto.Migration

  # Transaction types (afomi/bitblocks#49 phase 2, docs/TX_PIPELINE.md):
  #
  #   transactions.tx_types          the tx's type: the set of type ids from
  #                                  priv/data/tx_types/types.json its outputs
  #                                  (and their data protocols) match, in
  #                                  types.json order, e.g. {p2pkh,custom}.
  #                                  Written by the classify_outputs step.
  #   transactions.tx_types_version  TxPipeline.version(:tx_types), stamped
  #                                  with it; nil until typed.
  #   blocks.type_counts             per block: type id => txs of that type,
  #                                  written by the type_counts step when the
  #                                  block completes. Summed for /types.
  #   blocks.type_counts_version     TxPipeline.version(:type_counts), set only
  #                                  when every tx of the block is typed at the
  #                                  current version; nil otherwise.
  #
  # Nullable with no default, so Postgres records the columns in the catalog
  # and rewrites nothing: safe on the 10M+ row transactions table. No index
  # (AGENTS.md, "Migrations on large tables"): counts are read from blocks,
  # and the backfill finds its rows per block through the block_hash index.
  #
  # The ALTER still takes a brief ACCESS EXCLUSIVE lock; lock_timeout makes it
  # fail fast (and the deploy retry) rather than queue every tx write behind a
  # long-running read.
  def change do
    execute("SET LOCAL lock_timeout = '10s'", "")

    alter table(:transactions) do
      add(:tx_types, {:array, :string})
      add(:tx_types_version, :integer)
    end

    alter table(:blocks) do
      add(:type_counts, :map)
      add(:type_counts_version, :integer)
    end
  end
end
