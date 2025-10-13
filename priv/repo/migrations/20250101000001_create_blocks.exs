defmodule Bitblocks.Repo.Migrations.CreateBlocks do
  use Ecto.Migration

  def change do
    create table(:blocks) do
      add :hash, :string, null: false
      add :num_tx, :integer
      add :timestamp, :naive_datetime
      add :bits, :string
      add :chainwork, :string
      add :difficulty, :string
      add :height, :integer, null: false
      add :mediantime, :integer
      add :merkleroot, :string
      add :nextblockhash, :string
      add :prevblockhash, :string
      add :nonce, :bigint
      add :size, :bigint
      add :time, :integer
      add :version, :integer
      add :tx, {:array, :string}
      add :sync_state, :string, default: "pending", null: false
      add :tx_sync_started_at, :utc_datetime
      add :tx_sync_completed_at, :utc_datetime
      add :tx_sync_error, :text
      add :tx_sync_attempts, :integer, default: 0

      timestamps()
    end

    create unique_index(:blocks, [:height])
    create unique_index(:blocks, [:hash])
    create index(:blocks, [:inserted_at])
    create index(:blocks, [:sync_state])
    create index(:blocks, [:sync_state, :height])
  end
end
