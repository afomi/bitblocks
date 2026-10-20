defmodule Bitblocks.Chain.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transactions" do
    field :raw, :string
    field :version, :string
    field :inputs, {:array, :string}
    field :input_txids, {:array, :string}
    field :txid, :string
    field :block_hash, :string
    field :block_height, :integer
    field :outputs, {:array, :string}
    field :output_addresses, {:array, :string}
    field :total_output_satoshis, :integer
    field :total_input_satoshis, :integer
    field :input_count, :integer
    field :output_count, :integer

    # Script analysis — derived deterministically from raw.
    # script_analysis_version tracks which analyzer version produced these fields.
    # Bump Bitblocks.TransactionAnalyzer.current_version() to trigger reanalysis.
    field :output_types, :map
    field :protocols, {:array, :string}
    field :coinbase, :boolean
    field :script_analysis_version, :integer

    # Script-first indexing (analyze v5): deduplicated per-tx arrays of
    # Electrum-convention scripthashes and opcode-skeleton template hashes for
    # every output's locking script. GIN-indexed; see Bitblocks.Script.
    field :output_script_hashes, {:array, :string}
    field :output_template_hashes, {:array, :string}

    # Analyze v6: addresses of valid AIP signatures in this tx (GIN-indexed),
    # so "everything signed by X" is one indexed query. See Bitblocks.Aip.
    field :aip_signers, {:array, :string}, default: []

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
      :input_txids,
      :outputs,
      :output_addresses,
      :total_output_satoshis,
      :total_input_satoshis,
      :input_count,
      :output_count,
      :output_types,
      :protocols,
      :coinbase,
      :script_analysis_version,
      :output_script_hashes,
      :output_template_hashes,
      :aip_signers
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
