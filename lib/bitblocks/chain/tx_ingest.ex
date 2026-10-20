defmodule Bitblocks.Chain.TxIngest do
  @moduledoc """
  The single ingest path for a fetched transaction: body-hash check, script
  analysis, insert, spend recording, token indexing.

  Both tx-fetch workers (`FetchTransactionsWorker`, `BackfillTransactionsWorker`)
  store through here so their pipelines cannot drift — previously the backfill
  lane skipped the body-hash check and token indexing that the tip lane applied.

  Idempotent: inserts use `on_conflict: :nothing` on the unique txid, so
  re-processing an already-stored transaction is a no-op.
  """

  require Logger

  alias Bitblocks.{Chain, Repo}
  alias Bitblocks.Chain.Block
  alias Bitblocks.TransactionParser

  @doc """
  Stores one transaction (a `getrawtransaction` verbosity-1 map) for `block`.

  Returns `:ok`, or `{:error, {:body_txid_mismatch, txid}}` /
  `{:error, {:insert_failed, txid}}` — callers count errors against the batch
  so the block can never be marked complete around them.
  """
  def store(tx_json, %Block{} = block) when is_map(tx_json) do
    txid = tx_json["txid"]
    raw = tx_json["hex"]

    if body_matches_txid?(raw, txid) do
      insert(tx_json, txid, raw, block)
    else
      Logger.error(
        "TxIngest block=#{block.height} REJECTED tx #{txid} — body does not hash to txid"
      )

      {:error, {:body_txid_mismatch, txid}}
    end
  end

  @doc """
  True iff `raw` decodes and its computed txid equals `expected`. Total: a
  non-binary or undecodable body simply fails the check (fail closed). A nil
  raw means the node returned no body — let it through so the changeset path
  handles it (the txid is already merkleroot-authed).
  """
  def body_matches_txid?(nil, _expected), do: true

  def body_matches_txid?(raw, expected) when is_binary(raw) do
    case Bitblocks.Chain.SafeTx.from_hex(raw) do
      {:ok, tx} -> BSV.Tx.get_txid(tx) == expected
      {:error, _} -> false
    end
  end

  def body_matches_txid?(_raw, _expected), do: false

  defp insert(tx_json, txid, raw, block) do
    analysis =
      case TransactionParser.analyze(raw) do
        {:ok, meta} -> meta
        _ -> %{}
      end

    inputs = (tx_json["vin"] || []) |> Enum.map(&Jason.encode!/1)
    outputs = (tx_json["vout"] || []) |> Enum.map(&Jason.encode!/1)

    attrs =
      Map.merge(
        %{
          txid: txid,
          raw: raw,
          block_hash: tx_json["blockhash"] || block.hash,
          block_height: tx_json["height"] || block.height,
          version: to_string(tx_json["version"] || 1),
          inputs: inputs,
          input_txids: TransactionParser.extract_input_txids(inputs),
          outputs: outputs,
          output_addresses: TransactionParser.extract_output_addresses(outputs)
        },
        analysis
      )

    changeset = Chain.Transaction.changeset(%Chain.Transaction{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :txid) do
      {:ok, tx} ->
        Chain.record_spends(tx)
        # Index any BSV-20/21 token inscriptions this tx carries (no-op unless
        # it was tagged "BSV20" during analyze).
        Chain.index_tokens(tx)
        # Log Bitcom `$` commands and ownership proofs (no-op unless tagged "Bitcom").
        Chain.index_bitcom(tx)
        :ok

      {:error, changeset} ->
        Logger.error("TxIngest failed to store tx #{txid}: #{inspect(changeset.errors)}")
        {:error, {:insert_failed, txid}}
    end
  end
end
