defmodule Bitblocks.Chain.BlockTxids do
  @moduledoc """
  One page of a block's txids, for the block page.

  The block row's `tx` array is used when it holds the list. Many completed
  blocks have none: the raw-block path and blocks over 10,000 txs don't keep
  it on the row. Those page through the stored transactions instead, on
  `transactions_block_hash_index`, in insertion order, which is block order
  because a block is stored sequentially by one worker.
  """
  import Ecto.Query

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Repo

  @spec page(Block.t(), pos_integer(), pos_integer()) :: [String.t()]
  def page(%Block{} = block, page, size) when page >= 1 and size >= 1 do
    case Chain.block_txids_page(block.id, page, size) do
      [] -> stored_page(block.hash, page, size)
      txids -> txids
    end
  end

  defp stored_page(hash, page, size) do
    Repo.all(
      from(t in Transaction,
        where: t.block_hash == ^hash,
        order_by: [asc: t.id],
        offset: ^((page - 1) * size),
        limit: ^size,
        select: t.txid
      )
    )
  end

  @doc """
  What the block page shows beside each txid on a page: the stored row's
  types, total output and whether it is the coinbase, keyed by txid. One
  query on the txid index for at most a page of txids; a txid we don't
  store is absent.
  """
  @spec summaries(Block.t(), [String.t()]) :: %{String.t() => map()}
  def summaries(_block, []), do: %{}

  def summaries(%Block{hash: hash}, txids) when is_list(txids) do
    from(t in Transaction,
      where: t.txid in ^txids and t.block_hash == ^hash,
      select:
        {t.txid, %{tx_types: t.tx_types, sats_out: t.total_output_satoshis, coinbase: t.coinbase}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "How many of the block's transactions are stored (one indexed count)."
  @spec count(Block.t()) :: non_neg_integer()
  def count(%Block{hash: hash}) do
    Repo.one(from(t in Transaction, where: t.block_hash == ^hash, select: count(t.id)))
  end
end
