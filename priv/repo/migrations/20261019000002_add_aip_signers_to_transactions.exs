defmodule Bitblocks.Repo.Migrations.AddAipSignersToTransactions do
  use Ecto.Migration

  # Analyze v6: the addresses of valid AIP signatures in a tx, verified with
  # the same message rule qart signs with (Bitblocks.Aip). GIN-indexed so
  # "every tx signed by address X" is one indexed lookup. Derived from `raw`
  # by TransactionParser.analyze/1; backfilled by Release.analyze_transactions/1.
  def change do
    alter table(:transactions) do
      add(:aip_signers, {:array, :string}, default: [])
    end

    create(index(:transactions, [:aip_signers], using: "GIN"))
  end
end
