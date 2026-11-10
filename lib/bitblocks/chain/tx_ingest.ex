defmodule Bitblocks.Chain.TxIngest do
  @moduledoc """
  The single ingest path for a fetched transaction: body-hash check, then
  the tx pipeline around the insert (`Chain.TxPipeline`: analysis and
  tallies before it, spends, tokens and Bitcom after it).

  Both tx-fetch workers (`FetchTransactionsWorker`, `BackfillTransactionsWorker`)
  store through here so their pipelines cannot drift — previously the backfill
  lane skipped the body-hash check and token indexing that the tip lane applied.

  Idempotent: inserts use `on_conflict: :nothing` on the unique txid, so
  re-processing an already-stored transaction is a no-op. The diff before
  the insert (`existing_txids/2`) is where a transaction re-mined after a
  reorg is moved off the orphaned block (#34).
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.{Chain, Repo}
  alias Bitblocks.Chain.{Block, TxPipeline}
  alias Bitblocks.Reorgs.ProtocolRewind
  alias Bitblocks.TransactionParser

  @doc """
  Which of `txids` (a chunk of `block`'s verified txid list) are already
  stored, as a MapSet. The workers skip these.

  A stored row whose `block_hash` is no longer a stored block was left behind
  by a reorg: the orphan was deleted and this block holds the transaction now.
  Those rows are moved to `block` (hash and height) here, since the skip means
  the insert never runs for them, and the protocol rows derived from them
  follow in the same database transaction (`Reorgs.ProtocolRewind`). A row
  under another block that is still stored (a duplicate coinbase txid) is left
  alone.

  A row this block holds but that was stored without its place (no
  `block_hash`, or this hash and no `block_height`, from ingest before the
  height was written) is placed here the same way, so the fill heals it
  rather than skipping it as stored.

  Costs one query on the unique txid index per chunk; a second, on `blocks`,
  only when some row sits under another hash.
  """
  @spec existing_txids([String.t()], Block.t()) :: MapSet.t()
  def existing_txids([], _block), do: MapSet.new()

  def existing_txids(txids, %Block{hash: hash, height: height}) when is_list(txids) do
    placed =
      Repo.all(
        from(t in Chain.Transaction,
          where: t.txid in ^txids,
          select: {t.txid, t.block_hash, t.block_height}
        )
      )

    place_unplaced(placed, hash, height)

    rows = for {txid, block_hash, _} <- placed, do: {txid, block_hash}

    elsewhere = for {txid, other} <- rows, other != nil, other != hash, do: {txid, other}

    if elsewhere != [] do
      other_hashes = elsewhere |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      stored =
        Repo.all(from(b in Block, where: b.hash in ^other_hashes, select: b.hash))
        |> MapSet.new()

      orphaned = Enum.reject(other_hashes, &MapSet.member?(stored, &1))

      moving =
        for {txid, other} <- elsewhere, other in orphaned, do: txid

      if moving != [] do
        {:ok, count} =
          Repo.transaction(fn ->
            {count, _} =
              Repo.update_all(
                from(t in Chain.Transaction,
                  where: t.txid in ^moving and t.block_hash in ^orphaned
                ),
                set: [
                  block_hash: hash,
                  block_height: height,
                  updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
                ]
              )

            ProtocolRewind.moved(moving, hash, height)
            count
          end)

        Logger.info(
          "TxIngest block=#{height} moved #{count} tx(s) off orphaned block(s) #{inspect(orphaned)}"
        )
      end
    end

    rows |> Enum.map(&elem(&1, 0)) |> MapSet.new()
  end

  defp place_unplaced(rows, hash, height) do
    unplaced =
      for {txid, block_hash, block_height} <- rows,
          is_nil(block_hash) or (block_hash == hash and is_nil(block_height)),
          do: txid

    if unplaced != [] and is_integer(height) do
      {:ok, count} =
        Repo.transaction(fn ->
          {count, _} =
            Repo.update_all(
              from(t in Chain.Transaction,
                where: t.txid in ^unplaced,
                where: is_nil(t.block_hash) or (t.block_hash == ^hash and is_nil(t.block_height))
              ),
              set: [
                block_hash: hash,
                block_height: height,
                updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
              ]
            )

          ProtocolRewind.moved(unplaced, hash, height)
          count
        end)

      Logger.info("TxIngest block=#{height} placed #{count} tx(s) stored without their block")
    end
  end

  @doc """
  Stores one transaction (a `getrawtransaction` verbosity-1 map) for `block`.
  The one-tx case of `store_chunk/2`.

  Returns `:ok`, or `{:error, {:body_txid_mismatch, txid}}` /
  `{:error, {:insert_failed, txid}}` — callers count errors against the batch
  so the block can never be marked complete around them.
  """
  def store(tx_json, %Block{} = block) when is_map(tx_json) do
    [{_txid, result}] = store_chunk([tx_json], block)
    result
  end

  @doc """
  Stores a chunk of `block`'s transactions, given in block order, through the
  tx pipeline (`Chain.TxPipeline`, `docs/TX_PIPELINE.md`):

    1. the body-hash check, per tx (a tx that fails it goes no further);
    2. the `:chunk` steps over the chunk's rows (analysis and tallies), so
       their columns go in with the insert;
    3. the insert, per tx;
    4. the `:tx` steps for each stored tx (spends, tokens, Bitcom).

  Returns `[{txid, :ok | {:error, reason}}]` in the order given. A pipeline
  step that fails is logged and reported; it never turns a stored tx into an
  error.
  """
  @spec store_chunk([map()], Block.t()) :: [{String.t(), :ok | {:error, term()}}]
  def store_chunk(tx_jsons, %Block{} = block) when is_list(tx_jsons) do
    checked =
      Enum.map(tx_jsons, fn tx_json ->
        txid = tx_json["txid"]

        if body_matches_txid?(tx_json["hex"], txid) do
          {:ok, base_attrs(tx_json, block)}
        else
          Logger.error(
            "TxIngest block=#{block.height} REJECTED tx #{txid} — body does not hash to txid"
          )

          {:error, txid, {:body_txid_mismatch, txid}}
        end
      end)

    derived =
      checked
      |> Enum.flat_map(fn
        {:ok, attrs} -> [attrs]
        _ -> []
      end)
      |> TxPipeline.run_chunk(block)

    {results, []} =
      Enum.map_reduce(checked, derived, fn
        {:ok, _}, [attrs | rest] -> {{attrs.txid, insert(attrs, block)}, rest}
        {:error, txid, reason}, rest -> {{txid, {:error, reason}}, rest}
      end)

    results
  end

  @doc """
  True iff `raw` (hex) hashes to `expected`: the txid is the double SHA-256
  of the bytes, byte-reversed. Total: a non-binary or non-hex body fails the
  check (fail closed). A nil raw means the node returned no body — let it
  through so the changeset path handles it (the txid is already
  merkleroot-authed).

  The bytes are hashed, not decoded and re-encoded: a script need not parse
  as opcodes (data after a contract often doesn't), and `BSV.Tx.from_binary`
  raises on those, which used to reject genuine txs and leave their blocks
  incomplete.
  """
  def body_matches_txid?(nil, _expected), do: true

  def body_matches_txid?(raw, expected) when is_binary(raw) and is_binary(expected) do
    with true <- byte_size(raw) <= Bitblocks.Chain.SafeTx.max_hex_bytes(),
         {:ok, bytes} <- Base.decode16(raw, case: :mixed) do
      :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))
      |> :binary.bin_to_list()
      |> Enum.reverse()
      |> :binary.list_to_bin()
      |> Base.encode16(case: :lower) == String.downcase(expected)
    else
      _ -> false
    end
  end

  def body_matches_txid?(_raw, _expected), do: false

  defp base_attrs(tx_json, block) do
    inputs = (tx_json["vin"] || []) |> Enum.map(&Jason.encode!/1)
    outputs = (tx_json["vout"] || []) |> Enum.map(&Jason.encode!/1)

    %{
      txid: tx_json["txid"],
      raw: tx_json["hex"],
      block_hash: tx_json["blockhash"] || block.hash,
      block_height: tx_json["height"] || block.height,
      version: to_string(tx_json["version"] || 1),
      inputs: inputs,
      input_txids: TransactionParser.extract_input_txids(inputs),
      outputs: outputs,
      output_addresses: TransactionParser.extract_output_addresses(outputs),
      # Where the tx sits in its raw block, when it came from one. Read only
      # once the block's object is verified (blocks.raw_object_stored_at), so
      # writing it here saves rewriting every row after the object lands.
      raw_offset: tx_json["raw_offset"],
      raw_length: tx_json["raw_length"]
    }
  end

  defp insert(attrs, block) do
    changeset = Chain.Transaction.changeset(%Chain.Transaction{}, attrs)

    # The insert and the :tx steps commit together: a step that fails rolls
    # the row back, so the block's retry (which skips stored txids) redoes
    # the whole tx instead of leaving its spends or tokens unrecorded.
    result =
      Repo.transaction(fn ->
        case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :txid) do
          {:ok, tx} ->
            case Enum.find(TxPipeline.run_tx(tx, block), &match?({_, {:error, _}}, &1)) do
              nil -> :ok
              {step, _error} -> Repo.rollback({:tx_step_failed, attrs.txid, step})
            end

          {:error, changeset} ->
            Repo.rollback({:changeset, changeset})
        end
      end)

    case result do
      {:ok, :ok} ->
        :ok

      {:error, {:tx_step_failed, _, _} = reason} ->
        {:error, reason}

      {:error, {:changeset, changeset}} ->
        Logger.error("TxIngest failed to store tx #{attrs.txid}: #{inspect(changeset.errors)}")
        {:error, {:insert_failed, attrs.txid}}
    end
  end
end
