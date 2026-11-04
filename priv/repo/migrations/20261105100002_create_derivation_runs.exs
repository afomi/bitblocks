defmodule Bitblocks.Repo.Migrations.CreateDerivationRuns do
  use Ecto.Migration

  # One row per backfill run of derived data: the provenance of the backfill
  # itself (docs/DERIVED_DATA.md). Every run writes one, dry runs included,
  # so "who computed this, at which version, and when" has an answer for the
  # rows a backfill touched, and "is the range complete" has a recorded one.
  #
  # A small table: a few rows per backfill command, never per tx.
  def change do
    create table(:derivation_runs) do
      # What was derived: a derivation of the tx pipeline, e.g. "tallies" or
      # "script_analysis" (TxPipeline.derivations/0).
      add(:derivation, :string, null: false)
      # The derivation's version the run brought rows up to
      # (TxPipeline.version/1 at the time of the run).
      add(:version, :integer, null: false)

      # The block height range, inclusive. Both nil for a run over every
      # stored transaction (Release.analyze_transactions/1).
      add(:from_height, :integer)
      add(:to_height, :integer)

      # false: a dry run, which reads and counts and writes nothing but this
      # row. true: applied.
      add(:applied, :boolean, null: false, default: false)

      # Counts. rows_examined: rows the run read; rows_changed: rows it
      # stamped (or, in a dry run, would stamp); rows_below_version: rows in
      # the range still below the version when it finished, 0 for a complete
      # applied run. blocks_examined: blocks in the range it walked.
      add(:rows_examined, :bigint, null: false, default: 0)
      add(:rows_changed, :bigint, null: false, default: 0)
      add(:rows_below_version, :bigint)
      add(:blocks_examined, :bigint, null: false, default: 0)

      # Derivation-specific counts (e.g. values_changed, sats_in_unknown,
      # blocks_changed, undecodable, unverified heights).
      add(:details, :map, null: false, default: %{})

      # running (in flight, or the process died), ok (every batch done),
      # partial (stopped by an error after at least one batch; the batches
      # before it stay applied), failed (stopped before finishing any batch).
      add(:outcome, :string, null: false, default: "running")
      # The error that stopped a partial or failed run.
      add(:error, :text)

      # The command as typed, e.g.
      # Release.backfill_tx_tallies(0, 10000, apply: true).
      add(:command, :text)

      add(:started_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)

      timestamps()
    end

    # "Latest runs", overall and per derivation.
    create(index(:derivation_runs, [:started_at]))
    create(index(:derivation_runs, [:derivation, :started_at]))
  end
end
