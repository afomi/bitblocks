defmodule Bitblocks.Burns do
  @moduledoc """
  Sats burned on chain: locked in OP_RETURN outputs, which can never be spent.

  Two exact tallies from `Chain.TxPipeline`, no classification:

    * `blocks.burned`, summed per block by the `block_totals` step, so it
      reaches only as far as completed, totalled blocks;
    * `transactions.burned_satoshis`, per tx by the `burned` chunk step
      (nil on rows stored before the step and not yet backfilled).

  Reads are bounded: `blocks/1` reads `blocks` only, and `txs/2` reads the
  txs of one block through the `block_hash` index. There is no index on
  `burned_satoshis`, so there is no chain-wide "largest burning tx" query.
  `/burns` is the admin page over this module.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Repo

  @default_limit 100
  @max_limit 500
  @tx_limit 200
  @timeout 15_000

  @doc """
  Blocks that burned sats, `order: :burned` (most first, the default) or
  `order: :height` (newest first), up to `limit:` (#{@default_limit}, at most
  #{@max_limit}). Each is a map of height, hash, burned and num_tx.
  """
  @spec blocks(keyword()) :: [map()]
  def blocks(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    order =
      case Keyword.get(opts, :order, :burned) do
        :height -> [desc: dynamic([b], b.height)]
        _ -> [desc: dynamic([b], b.burned), desc: dynamic([b], b.height)]
      end

    from(b in Block,
      where: b.burned > 0,
      order_by: ^order,
      limit: ^limit,
      select: %{height: b.height, hash: b.hash, burned: b.burned, num_tx: b.num_tx}
    )
    |> Repo.all(timeout: @timeout)
  end

  @doc """
  How many blocks burned sats, and how many sats in all, over the blocks
  totalled so far.
  """
  @spec summary() :: %{blocks: non_neg_integer(), burned: non_neg_integer()}
  def summary do
    from(b in Block,
      where: b.burned > 0,
      select: %{blocks: count(b.id), burned: fragment("coalesce(sum(?), 0)::bigint", b.burned)}
    )
    |> Repo.one(timeout: @timeout)
  end

  @doc """
  The stored txs of one block that burned sats, most first, up to `limit`
  (#{@tx_limit}). Each is a map of txid and burned.
  """
  @spec txs(String.t(), pos_integer()) :: [map()]
  def txs(block_hash, limit \\ @tx_limit) when is_binary(block_hash) do
    from(t in Transaction,
      where: t.block_hash == ^block_hash and t.burned_satoshis > 0,
      order_by: [desc: t.burned_satoshis, asc: t.txid],
      limit: ^limit,
      select: %{txid: t.txid, burned: t.burned_satoshis}
    )
    |> Repo.all(timeout: @timeout)
  end

  @doc """
  How many stored txs of one block burned sats, and their sum, to set
  against the block's own total.
  """
  @spec tx_summary(String.t()) :: %{txs: non_neg_integer(), burned: non_neg_integer()}
  def tx_summary(block_hash) when is_binary(block_hash) do
    from(t in Transaction,
      where: t.block_hash == ^block_hash and t.burned_satoshis > 0,
      select: %{
        txs: count(t.id),
        burned: fragment("coalesce(sum(?), 0)::bigint", t.burned_satoshis)
      }
    )
    |> Repo.one(timeout: @timeout)
  end
end
