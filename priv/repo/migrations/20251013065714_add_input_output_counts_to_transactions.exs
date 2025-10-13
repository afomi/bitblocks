defmodule Bitblocks.Repo.Migrations.AddInputOutputCountsToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :input_count, :integer
      add :output_count, :integer
    end

    # Add indexes for performance
    create index(:transactions, [:input_count])
    create index(:transactions, [:output_count])
  end
end
