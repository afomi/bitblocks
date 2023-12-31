defmodule Bitblocks.Chain.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transactions" do
    field :raw, :string
    field :version, :string
    field :inputs, {:array, :string}
    field :txid, :string
    field :block_hash, :string
    field :outputs, {:array, :string}

    timestamps()
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:txid, :raw, :version, :block_hash, :inputs, :outputs])
    |> validate_required([:txid, :raw, :version, :block_hash, :inputs, :outputs])
  end
end
