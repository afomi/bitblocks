defmodule Bitblocks.Chain.BlockTxids do
  @moduledoc """
  One page of a block's txids, for the block page.

  The block row's `tx` array is used when it holds the list. Many blocks
  have none: the raw-block path and blocks over 10,000 txs don't keep it on
  the row, and a block above the sync has no stored txs at all. Those page
  through the stored transactions instead.

  Every read here is bounded, whatever the block's size or state:

    * the total comes from the row (the txid list's length, or `num_tx` once
      the block is `completed`), else from a count capped at
      #{100_000} rows, never a full count of a block with millions of txs;
    * no total, no page query: a block with no stored txs costs nothing;
    * a block of at most #{20_000} stored txs pages in block order off
      `transactions_block_hash_index` (insertion order, which is block order
      because one worker stores a block sequentially), sorting at most that
      many rows;
    * a bigger block pages in txid order off
      `transactions_block_height_txid_index`, which stops after the page.
      It filters on `block_height` alone, with sorts and bitmap scans off
      for that one query: with `block_hash` in the filter too, the planner
      multiplies the two columns' selectivities (one determines the other),
      expects a few dozen rows, and sorts every stored row of the block
      instead, about one cold heap page per row on a half-stored block of
      97,100. Rows at the height but under another hash (an orphan not yet
      reconciled) drop out, since `summaries/2` checks the hash.

  Ordering by the bare `id` let Postgres walk `transactions_pkey` and filter
  on `block_hash`, expecting to find a page early; for a block with few or
  no stored rows that reads the whole table. The block-order query sorts on
  `id + 0`, which the primary key can't serve, so it never takes that plan.

  `load/5` runs it all in one transaction under a `statement_timeout`, so a
  slow read comes back as `{:error, :timeout}` in seconds, not a pool
  connection held for minutes.
  """
  import Ecto.Query

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Repo

  # Stored txs at or under this page in block order; over it, in txid order.
  @block_order_max 20_000
  # A block not yet complete counts its stored txs up to this many.
  @count_cap 100_000
  @timeout_ms 5_000

  @type loaded :: %{
          total: non_neg_integer(),
          total_capped: boolean(),
          order: :block | :txid,
          page: pos_integer(),
          txids: [String.t()],
          summaries: %{String.t() => map()}
        }

  @doc """
  One page of the block's txids with their summaries and the total to page
  through, under a statement timeout.

  `list_total` is the length of the row's txid list (0 when it has none),
  as `Chain.get_block_for_display!/1` returns it.

  Options: `timeout_ms:` (default the `:block_page_read_timeout_ms` config,
  else #{@timeout_ms}).
  """
  @spec load(Block.t(), non_neg_integer(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, loaded()} | {:error, :timeout | :unavailable}
  def load(%Block{} = block, list_total, page, size, opts \\ [])
      when page >= 1 and size >= 1 do
    timeout_ms = Keyword.get_lazy(opts, :timeout_ms, &timeout_ms/0)

    Repo.with_statement_timeout(timeout_ms, fn ->
      {total, capped} = total(block, list_total)

      order =
        if list_total > 0 or total <= @block_order_max, do: :block, else: :txid

      txids =
        cond do
          total == 0 -> []
          list_total > 0 -> Chain.block_txids_page(block.id, page, size)
          true -> stored_page(block, order, page, size)
        end

      summaries = summaries(block, txids)
      txids = if order == :txid, do: Enum.filter(txids, &Map.has_key?(summaries, &1)), else: txids

      %{
        total: total,
        total_capped: capped,
        order: order,
        page: page,
        txids: txids,
        summaries: summaries
      }
    end)
  end

  defp timeout_ms, do: Application.get_env(:bitblocks, :block_page_read_timeout_ms, @timeout_ms)

  defp total(_block, list_total) when list_total > 0, do: {list_total, false}

  defp total(%Block{sync_state: "completed", num_tx: n}, _) when is_integer(n) and n > 0,
    do: {n, false}

  defp total(block, _) do
    case count(block, @count_cap + 1) do
      n when n > @count_cap -> {@count_cap, true}
      n -> {n, false}
    end
  end

  @doc """
  One page of the block's txids: the row's list when it has one, else the
  stored txs (see the moduledoc for the order). Unbounded by time; the block
  page uses `load/5`.
  """
  @spec page(Block.t(), pos_integer(), pos_integer()) :: [String.t()]
  def page(%Block{} = block, page, size) when page >= 1 and size >= 1 do
    case Chain.block_txids_page(block.id, page, size) do
      [] -> stored_page(block, :block, page, size)
      txids -> txids
    end
  end

  @doc false
  def stored_page_query(%Block{hash: hash}, :block, page, size) do
    # `id + 0`: sort the block's own rows; the primary key can't serve this
    # order, so the planner can't walk it and filter (see the moduledoc).
    from(t in Transaction,
      where: t.block_hash == ^hash,
      order_by: [asc: fragment("? + 0", t.id)],
      offset: ^((page - 1) * size),
      limit: ^size,
      select: t.txid
    )
  end

  def stored_page_query(%Block{height: height}, :txid, page, size) do
    # The height alone: see the moduledoc on why not the hash as well.
    from(t in Transaction,
      where: t.block_height == ^height,
      order_by: [asc: t.block_height, asc: t.txid],
      offset: ^((page - 1) * size),
      limit: ^size,
      select: t.txid
    )
  end

  defp stored_page(block, :txid, page, size) do
    # Inside load/5's transaction: walk the (block_height, txid) index in
    # order and stop after the page, never sort the block's rows.
    Repo.query!("SET LOCAL enable_sort = off")
    Repo.query!("SET LOCAL enable_bitmapscan = off")
    txids = block |> stored_page_query(:txid, page, size) |> Repo.all()
    Repo.query!("SET LOCAL enable_sort TO DEFAULT")
    Repo.query!("SET LOCAL enable_bitmapscan TO DEFAULT")
    txids
  end

  defp stored_page(block, order, page, size),
    do: block |> stored_page_query(order, page, size) |> Repo.all()

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

  @doc """
  How many of the block's transactions are stored, counting at most `cap`
  rows (`:infinity` for all) on `transactions_block_hash_index`.
  """
  @spec count(Block.t(), pos_integer() | :infinity) :: non_neg_integer()
  def count(block, cap \\ :infinity)

  def count(%Block{hash: hash}, :infinity) do
    Repo.one(from(t in Transaction, where: t.block_hash == ^hash, select: count(t.id)))
  end

  def count(%Block{hash: hash}, cap) when is_integer(cap) and cap > 0 do
    rows = from(t in Transaction, where: t.block_hash == ^hash, limit: ^cap, select: %{one: 1})
    Repo.one(from(r in subquery(rows), select: count()))
  end
end
