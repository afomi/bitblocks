defmodule Bitblocks.ProtocolRegistry.Instance do
  @moduledoc """
  Individual protocol instances found on-chain.

  Each instance represents a specific occurrence of a protocol
  in a transaction output (identified by txid:vout).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "protocol_instances" do
    belongs_to :protocol, Bitblocks.ProtocolRegistry.Protocol

    field :txid, :string
    field :vout, :integer
    field :block_height, :integer
    field :block_hash, :string

    # Parsed data from the OP_RETURN
    field :parsed_data, :map

    # State tracking for stateful protocols
    field :state, :map
    field :spent, :boolean, default: false
    field :spent_txid, :string

    timestamps()
  end

  @doc false
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :protocol_id,
      :txid,
      :vout,
      :block_height,
      :block_hash,
      :parsed_data,
      :state,
      :spent,
      :spent_txid
    ])
    |> validate_required([:protocol_id, :txid, :vout])
    |> unique_constraint([:txid, :vout])
  end

  @doc """
  Returns the outpoint string (txid:vout) for this instance.
  """
  def outpoint(%__MODULE__{txid: txid, vout: vout}), do: "#{txid}:#{vout}"
end
