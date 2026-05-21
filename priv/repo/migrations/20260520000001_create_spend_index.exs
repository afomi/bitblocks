defmodule Bitblocks.Repo.Migrations.CreateSpendIndex do
  use Ecto.Migration

  @doc """
  Phase 1 of progressive tx metadata: spent or not.

  The spend_index table records which outpoint (txid, vout) was consumed
  by which input (spending_txid, spending_vin). One row per spent output.

  If an outpoint has no row here, it is unspent (a live UTXO).
  """
  def change do
    create table(:spend_index) do
      # The output being spent
      add :txid, :string, null: false
      add :vout, :integer, null: false

      # The input that spent it
      add :spending_txid, :string, null: false
      add :spending_vin, :integer, null: false

      timestamps(updated_at: false)
    end

    # Primary lookup: "is this outpoint spent?"
    create unique_index(:spend_index, [:txid, :vout])

    # Reverse lookup: "which outpoints did this tx spend?"
    create index(:spend_index, [:spending_txid])
  end
end
