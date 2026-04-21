defmodule Bitblocks.Repo.Migrations.AddScriptAnalysisToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :output_types, :map, default: nil
      add :protocols, {:array, :string}, default: nil
      add :coinbase, :boolean, default: nil
      add :script_analysis_version, :integer, default: nil
    end

    create index(:transactions, [:script_analysis_version])
    create index(:transactions, [:protocols], using: :gin)
  end
end
