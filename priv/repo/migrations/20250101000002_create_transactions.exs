defmodule Bitblocks.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :txid, :string, null: false
      add :raw, :text
      add :version, :string
      add :block_hash, :string
      add :block_height, :integer
      add :inputs, {:array, :string}
      add :outputs, {:array, :string}
      add :total_input_satoshis, :bigint
      add :total_output_satoshis, :bigint

      timestamps()
    end

    create unique_index(:transactions, [:txid])
    create index(:transactions, [:block_hash])
    create index(:transactions, [:block_height])
    create index(:transactions, [:inserted_at])
    create index(:transactions, [:total_input_satoshis])
    create index(:transactions, [:total_output_satoshis])
  end
end
