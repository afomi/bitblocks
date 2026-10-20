defmodule Bitblocks.Chain.TxidSource do
  @moduledoc """
  Authoritative source for a block's txid list and expected transaction count.

  Both tx-fetch workers derive "what should this block contain" from here, so
  the completeness gate can never be satisfied by a truncated or empty stored
  `tx` array (the >10k memory optimization stores `[]`, which previously let a
  large block be marked `completed` with zero transactions stored).

  ## Expected count
  `num_tx` (from the PoW-verified header) is the denominator of record — a
  real block always has at least a coinbase, so `num_tx == 0`/nil means
  "unknown", and only then is the stored array's length trusted.

  ## Txid list
  The stored `tx` array is used only when it is complete (length == expected).
  Otherwise the list is re-fetched from the node via `getblock(hash, 1)` into
  process memory — never persisted above the threshold, so a 4M-txid block
  costs a transient list per fetch (bounded: both tx lanes are concurrency-1)
  instead of a permanent multi-hundred-MB table row.

  ## Verification
  Every list used — stored or fetched — is rebuilt into a merkleroot and
  checked against the header's (T4). This closes the previous hole where >10k
  blocks skipped the merkleroot check entirely because no full list existed.
  Mismatch fails closed. A verified list also self-heals the block row:
  `num_tx` is corrected if the header lacked it, and small blocks get their
  missing `tx` array persisted.
  """

  require Logger

  alias Bitblocks.Repo
  alias Bitblocks.Chain.{Block, MerkleVerifier}

  # Above this, the txid array is never persisted (memory optimization,
  # mirrored in Chain.do_upgrade_block_to_header_synced/1).
  @max_persisted_txids 10_000

  @doc """
  The number of transactions this block should have.

  Prefers the header's `num_tx`; falls back to the stored array length when
  the header didn't carry a count. Returns 0 only when both are unknown.
  """
  def expected_tx_count(%Block{num_tx: n}) when is_integer(n) and n > 0, do: n
  def expected_tx_count(%Block{tx: tx}) when is_list(tx), do: length(tx)
  def expected_tx_count(_block), do: 0

  @doc """
  Returns `{:ok, txids, block}` with a merkleroot-verified txid list, or
  `{:error, reason}`.

  Uses the stored array when complete; otherwise fetches the list from the
  node. The returned block reflects any self-healing (corrected `num_tx`,
  persisted array for small blocks).
  """
  def txids(%Block{} = block) do
    expected = expected_tx_count(block)

    if is_list(block.tx) and block.tx != [] and length(block.tx) == expected do
      with :ok <- verify_merkleroot(block, block.tx) do
        {:ok, block.tx, block}
      end
    else
      fetch_txids(block)
    end
  end

  defp fetch_txids(%Block{hash: hash, height: height} = block) do
    Logger.info(
      "TxidSource: block #{height} stored array incomplete " <>
        "(have=#{length(block.tx || [])} expected=#{expected_tx_count(block)}) — fetching txid list"
    )

    case rpc().getblock(hash, 1) do
      %{"tx" => txids} when is_list(txids) and txids != [] ->
        with :ok <- verify_merkleroot(block, txids),
             {:ok, block} <- self_heal(block, txids) do
          {:ok, txids, block}
        end

      %{} ->
        {:error, :no_txids_in_block_response}

      {:error, reason} ->
        {:error, reason}

      other ->
        Logger.error("TxidSource: unexpected getblock response for #{height}: #{inspect(other)}")
        {:error, :unexpected_response}
    end
  end

  # T4: rebuild the merkleroot from the (full) txid list and match it against
  # the PoW-verified header. Fails closed on mismatch — a wrong list must never
  # feed the completeness gate. Blocks without a stored merkleroot (partial
  # test fixtures, pre-verification rows) are allowed through with a warning;
  # the per-body txid hash check still applies downstream.
  defp verify_merkleroot(%Block{merkleroot: root} = block, txids)
       when is_binary(root) and root != "" do
    case MerkleVerifier.verify(txids, root) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "TxidSource: block #{block.height} REJECTED — txid list does not match " <>
            "header merkleroot: #{inspect(reason)}"
        )

        {:error, {:merkleroot_verification_failed, reason}}
    end
  end

  defp verify_merkleroot(block, _txids) do
    Logger.warning("TxidSource: block #{block.height} has no merkleroot — verification skipped")
    :ok
  end

  # A verified list is authoritative: correct num_tx if the header row
  # disagrees, and persist the array for small blocks so the next pass can use
  # it directly. Never persists arrays above @max_persisted_txids.
  defp self_heal(%Block{} = block, txids) do
    count = length(txids)

    changes =
      %{}
      |> then(fn ch -> if block.num_tx != count, do: Map.put(ch, :num_tx, count), else: ch end)
      |> then(fn ch ->
        if count <= @max_persisted_txids and block.tx != txids,
          do: Map.put(ch, :tx, txids),
          else: ch
      end)

    if changes == %{} do
      {:ok, block}
    else
      block
      |> Ecto.Changeset.change(changes)
      |> Repo.update()
    end
  end

  # Swappable RPC client — tests point this at BitcoinsvCliMock (config/test.exs).
  defp rpc, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
end
