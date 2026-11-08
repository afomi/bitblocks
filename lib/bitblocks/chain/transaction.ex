defmodule Bitblocks.Chain.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  # The largest tx whose full bytes stay in its row (docs/TX_STORAGE.md). The
  # tx store keeps every tx whatever this says. Changing it is a change to
  # the database: rows above or below it move, and an index names this number.
  @raw_in_db_max_bytes 1_000_000

  schema "transactions" do
    field :raw, :string
    # The tx's size in bytes, from its raw bytes. nil only on an older row
    # Release.backfill_tx_sizes/1 hasn't reached.
    field :size_bytes, :integer
    # True while the full raw bytes sit in this row; false once they live only
    # in the tx store. nil as size_bytes.
    field :raw_in_db, :boolean
    field :version, :string
    field :inputs, {:array, :string}
    field :input_txids, {:array, :string}
    field :txid, :string
    field :block_hash, :string
    field :block_height, :integer
    field :outputs, {:array, :string}
    field :output_addresses, {:array, :string}
    field :total_output_satoshis, :integer
    # Tallies (docs/TX_PIPELINE.md): sats in from stored previous outputs,
    # nil while any is unknown; fee = in - out (0 for a coinbase); burned =
    # sats in provably unspendable outputs.
    field :total_input_satoshis, :integer
    field :fee_satoshis, :integer
    field :burned_satoshis, :integer
    # Provenance for the four tallies: TxPipeline.version(:tallies) when they
    # were computed (at ingest, or by Release.backfill_tx_tallies/3); nil for
    # rows from before versions, which the backfill picks up. The row's
    # updated_at is when it was stamped. docs/DERIVED_DATA.md.
    field :tallies_version, :integer
    field :input_count, :integer
    field :output_count, :integer

    # Script analysis — derived deterministically from raw.
    # script_analysis_version tracks which analyzer version produced these fields.
    # Bump TransactionParser.script_analysis_version() (the script_analysis
    # step's version) to trigger reanalysis: Release.backfill_script_analysis/3.
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
    # The tx's type (afomi/bitblocks#49): the type ids from types.json its
    # outputs match, in types.json order (Bitblocks.TxTypes.Classifier), and
    # TxPipeline.version(:tx_types), the classifier version that typed it.
    # nil until typed; Release.backfill_tx_types/3 picks those up.
    field :tx_types, {:array, :string}
    field :tx_types_version, :integer
    # When raw bytes were written to the blob store and verified (Bitblocks.TxStore).
    field :blob_stored_at, :utc_datetime
    # Where this tx's bytes sit in its block's object in the tx store
    # (blocks/<height>-<hash>.bin): set with blocks.raw_object_stored_at,
    # once the object is written and verified. docs/TX_STORAGE.md.
    field :raw_offset, :integer
    field :raw_length, :integer

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
      :fee_satoshis,
      :burned_satoshis,
      :tallies_version,
      :input_count,
      :output_count,
      :output_types,
      :protocols,
      :coinbase,
      :script_analysis_version,
      :output_script_hashes,
      :output_template_hashes,
      :aip_signers,
      :tx_types,
      :tx_types_version,
      :raw_offset,
      :raw_length
    ])
    |> validate_required([:txid, :raw, :version, :block_hash, :inputs, :outputs])
    |> put_storage()
  end

  @doc "The largest tx, in bytes, whose full raw bytes stay in its row."
  def raw_in_db_max_bytes, do: @raw_in_db_max_bytes

  # A size and storage flag for every row, whichever path wrote it.
  defp put_storage(changeset) do
    case fetch_change(changeset, :raw) do
      {:ok, raw} when is_binary(raw) and raw != "" ->
        changeset
        |> put_change(:size_bytes, div(byte_size(raw), 2))
        |> put_change(:raw_in_db, true)

      _ ->
        changeset
    end
  end

  @doc """
  Calculates the miner fee for this transaction: the stored `fee_satoshis`
  when the tx pipeline has tallied it, else inputs minus outputs.
  Returns nil if input or output totals are not available.
  """
  def miner_fee(%__MODULE__{fee_satoshis: fee}) when is_integer(fee), do: fee
  def miner_fee(%__MODULE__{total_input_satoshis: nil}), do: nil
  def miner_fee(%__MODULE__{total_output_satoshis: nil}), do: nil

  def miner_fee(%__MODULE__{total_input_satoshis: inputs, total_output_satoshis: outputs}) do
    inputs - outputs
  end
end
