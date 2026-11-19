defmodule Bitblocks.Repo.Migrations.AddCheckpointToDerivationChains do
  use Ecto.Migration

  # A deploy costs a running backfill seconds, not a re-check of its range
  # (https://github.com/afomi/bitblocks/issues/115). Both nullable, no
  # default, no index: a metadata-only change on a small table.
  def change do
    alter table(:derivation_chains) do
      # The highest height (tx id for tx_size) of the range in flight whose
      # batch is committed; a job taking the range starts after it. Written
      # with the heartbeat after each batch; nil once the range is done.
      add(:checkpoint_height, :bigint)
      # When a job last stopped at a batch boundary on a node shutting down
      # and handed the range on.
      add(:handed_off_at, :utc_datetime_usec)
    end
  end
end
