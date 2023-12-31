defmodule Bitblocks.Chain.Block do
  use Ecto.Schema
  import Ecto.Changeset

  schema "blocks" do
    field :size, :integer
    field :timestamp, :naive_datetime
    field :version, :integer
    field :time, :integer
    field :bits, :string
    field :hash, :string
    field :num_tx, :integer
    field :chainwork, :string
    field :difficulty, :string
    field :height, :integer
    field :mediantime, :integer
    field :merkleroot, :string
    field :nextblockhash, :string
    field :prevblockhash, :string
    field :nonce, :integer
    field :tx, {:array, :string}

    timestamps()
  end

  @doc false
  def changeset(block, attrs) do
    block
    |> cast(attrs, [:hash, :num_tx, :timestamp, :bits, :chainwork, :difficulty, :height, :mediantime, :merkleroot, :nextblockhash, :prevblockhash, :nonce, :size, :time, :version])
    |> validate_required([:hash, :num_tx, :timestamp, :bits, :chainwork, :difficulty, :height, :mediantime, :merkleroot, :nextblockhash, :prevblockhash, :nonce, :size, :time, :version])
  end
end
