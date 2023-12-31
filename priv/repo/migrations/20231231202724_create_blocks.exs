defmodule Bitblocks.Repo.Migrations.CreateBlocks do
  use Ecto.Migration

  def change do
    create table(:blocks) do
      add :hash, :string
      add :num_tx, :integer
      add :timestamp, :naive_datetime
      add :bits, :string
      add :chainwork, :string
      add :difficulty, :string
      add :height, :integer
      add :mediantime, :integer
      add :merkleroot, :string
      add :nextblockhash, :string
      add :prevblockhash, :string
      add :nonce, :bigint
      add :size, :integer
      add :time, :integer
      add :version, :integer
      add :tx, {:array, :string}

      timestamps()
    end
  end
end
