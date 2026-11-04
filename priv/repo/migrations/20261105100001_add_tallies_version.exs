defmodule Bitblocks.Repo.Migrations.AddTalliesVersion do
  use Ecto.Migration

  # Provenance for derived data (docs/DERIVED_DATA.md): which version of the
  # tx pipeline computed a row's derived columns.
  #
  #   transactions.tallies_version  TxPipeline.version(:tallies), the sum of
  #                                 the sats_out, burned, sats_in and fee step
  #                                 versions, stamped at ingest and by
  #                                 Release.backfill_tx_tallies/3.
  #   blocks.tallies_version        TxPipeline.version(:block_totals), stamped
  #                                 by the block_totals step.
  #
  # nil means "computed before versions existed, or not computed": exactly
  # what the backfill picks up, along with any stamp below the current one.
  #
  # Nullable with no default, so Postgres records the columns in the catalog
  # and rewrites nothing: safe on the tens-of-GB transactions table.
  # No index (AGENTS.md, "Migrations on large tables"): the backfill finds its
  # rows per block through the existing block_hash index.
  def change do
    alter table(:transactions) do
      add(:tallies_version, :integer)
    end

    alter table(:blocks) do
      add(:tallies_version, :integer)
    end
  end
end
