defmodule Bitblocks.Repo.Migrations.CreateDerivationChains do
  use Ecto.Migration

  # A backfill run as Oban jobs, one range at a time (docs/DERIVED_DATA.md).
  # The row is the chain's state, so it survives a deploy: where it has got to,
  # whether an operator paused it, and a heartbeat that tells a live job from
  # one a restart killed.
  def change do
    create table(:derivation_chains) do
      # "script_analysis", "tx_steps", "tallies", "tx_types" or "tx_size".
      add(:derivation, :string, null: false)
      # false for a dry run: its derivation_runs rows hold the counts.
      add(:applied, :boolean, null: false, default: false)
      # Inclusive; block heights, or tx ids for tx_size.
      add(:range_from, :bigint, null: false)
      add(:range_to, :bigint, null: false)
      # How much of the range one job takes.
      add(:range_step, :bigint, null: false)
      # The start of the next range to run.
      add(:next_from, :bigint, null: false)
      # running, paused, cancelled, done or failed.
      add(:status, :string, null: false, default: "running")
      # The backfill's options: force, pause_ms, block_batch and so on.
      add(:opts, :map, null: false, default: %{})
      add(:error, :text)
      # Set while a job works a range, and on each of its batches; nil between
      # jobs. Fresh means a job is alive, so a rescued copy waits.
      add(:heartbeat_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)

      timestamps()
    end

    create(index(:derivation_chains, [:status]))

    alter table(:derivation_runs) do
      # The chain that ran this range; nil for a run started by hand.
      add(:chain_id, references(:derivation_chains, on_delete: :nilify_all))
    end

    create(index(:derivation_runs, [:chain_id]))
  end
end
