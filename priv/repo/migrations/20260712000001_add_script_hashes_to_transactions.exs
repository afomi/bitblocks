defmodule Bitblocks.Repo.Migrations.AddScriptHashesToTransactions do
  use Ecto.Migration

  # Script-first indexing: make every output queryable by its script, not just
  # by address (output_addresses only covers standard scripts the node could
  # derive an address for — custom scripts contribute nothing there).
  #
  # output_script_hashes — per-tx array of Electrum/WhatsOnChain scripthashes
  #   (sha256 of the raw scriptPubKey bytes, byte-reversed hex). One exact
  #   script → one hash; serves /api/v1/script/:scripthash/history|unspent.
  #
  # output_template_hashes — per-tx array of template hashes (sha256 of the
  #   script's opcode skeleton with push-data collapsed). Two instances of the
  #   same contract template with different args share a hash; serves the
  #   script_templates registry and "every use of this contract" queries.
  #
  # Both are derived from `raw` by TransactionParser.analyze/1 (v5) and
  # backfilled with Release.analyze_transactions/1. Deduplicated per tx.
  def change do
    alter table(:transactions) do
      add(:output_script_hashes, {:array, :string})
      add(:output_template_hashes, {:array, :string})
    end

    # GIN indexes make `?hash = ANY(column)` containment lookups fast at
    # tens-of-millions-of-rows scale, mirroring the output_addresses index.
    create(index(:transactions, [:output_script_hashes], using: "GIN"))
    create(index(:transactions, [:output_template_hashes], using: "GIN"))
  end
end
