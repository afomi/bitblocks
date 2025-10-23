defmodule Bitblocks.Chain.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transactions" do
    field :raw, :string
    field :version, :string
    field :inputs, {:array, :string}
    field :txid, :string
    field :block_hash, :string
    field :block_height, :integer
    field :outputs, {:array, :string}
    field :total_output_satoshis, :integer
    field :total_input_satoshis, :integer
    field :input_count, :integer
    field :output_count, :integer

    timestamps()
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :txid,
      :raw,
      :version,
      :block_hash,
      :block_height,
      :inputs,
      :outputs,
      :total_output_satoshis,
      :total_input_satoshis,
      :input_count,
      :output_count
    ])
    |> validate_required([:txid, :raw, :version, :block_hash, :inputs, :outputs])
  end

  @doc """
  Calculates the miner fee for this transaction.
  Returns nil if input or output totals are not available.
  """
  def miner_fee(%__MODULE__{total_input_satoshis: nil}), do: nil
  def miner_fee(%__MODULE__{total_output_satoshis: nil}), do: nil

  def miner_fee(%__MODULE__{total_input_satoshis: inputs, total_output_satoshis: outputs}) do
    inputs - outputs
  end
end
