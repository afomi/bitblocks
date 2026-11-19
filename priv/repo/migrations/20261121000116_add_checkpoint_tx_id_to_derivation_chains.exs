defmodule Bitblocks.Repo.Migrations.AddCheckpointTxIdToDerivationChains do
  use Ecto.Migration

  # A checkpoint inside a dense block, so a batch never has to finish a
  # whole block before a deploy can hand it off
  # (https://github.com/afomi/bitblocks/issues/115). Nullable, no default,
  # no index: a metadata-only change on a small table.
  def change do
    alter table(:derivation_chains) do
      # When set, the block at checkpoint_height is done only through this
      # transactions.id (ascending), and the next job resumes inside it,
      # after this id. Nil when that block is done whole.
      add(:checkpoint_tx_id, :bigint)
    end
  end
end
