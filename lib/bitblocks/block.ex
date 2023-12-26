defmodule Bitblocks.Block do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "blocks" do
    field :hash, :string
    field :tx, {:array, :string}
    field :num_tx, :integer
    field :timestamp, :naive_datetime
    field :bits, :string
    field :chainwork, :string
    field :difficulty, :float
    field :height, :integer
    field :mediantime, :integer
    field :merkleroot, :string
    field :nextblockhash, :string
    field :prevblockhash, :string
    field :nonce, :integer #:bigint
    field :size, :integer
    field :time, :integer
    field :version, :integer
  end
end
