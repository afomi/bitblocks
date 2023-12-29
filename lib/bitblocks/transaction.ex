defmodule Bitblocks.Transaction do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "transactions" do
    field :txid, :string
    field :raw, :string
    field :version, :string

    field :block_hash, :string
    field :inputs, {:array, :string}
    field :outputs, {:array, :string}
  end
end
