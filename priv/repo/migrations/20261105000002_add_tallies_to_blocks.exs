defmodule Bitblocks.Repo.Migrations.AddTalliesToBlocks do
  use Ecto.Migration

  # Block totals, written when a block becomes `completed` (the
  # `block_totals` step, docs/TX_PIPELINE.md). All nullable: nil until then.
  #
  #   sats_out      sum of non-coinbase outputs
  #   fees          sum of non-coinbase fees; nil if any is unknown
  #   miner_reward  the coinbase's total output
  #   subsidy       from height: 50 BTC, halving every 210,000 blocks
  #   burned        sum of burned sats
  #   fees_verified miner_reward <= subsidy + fees; nil while fees are unknown
  def change do
    alter table(:blocks) do
      add(:sats_out, :bigint)
      add(:fees, :bigint)
      add(:miner_reward, :bigint)
      add(:subsidy, :bigint)
      add(:burned, :bigint)
      add(:fees_verified, :boolean)
    end
  end
end
