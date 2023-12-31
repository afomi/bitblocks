defmodule Bitblocks.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :txid, :string
      add :raw, :text
      add :version, :string
      add :block_hash, :string
      add :inputs, {:array, :string}
      add :outputs, {:array, :string}

      timestamps()
    end
  end
end
