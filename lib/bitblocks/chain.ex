defmodule Bitblocks.Chain do
  @moduledoc """
  The Chain context.
  """

  import Ecto.Query, warn: false
  alias Bitblocks.Repo

  alias Bitblocks.Chain.Block
  alias Bitblocks.Chain.Spend
  alias Bitblocks.Chain.Transaction

  @pubsub Bitblocks.PubSub

  @doc ~S"""
  Broadcasts a block state change to all subscribers.

  Any LiveView showing this block can subscribe to `"block:#{hash}"` or
  `"blocks"` (for list views) to get real-time updates.

  Payload: `{:block_updated, %Block{}}`.
  """
  def broadcast_block_update(%Block{} = block) do
    Phoenix.PubSub.broadcast(@pubsub, "block:#{block.hash}", {:block_updated, block})
    Phoenix.PubSub.broadcast(@pubsub, "blocks", {:block_updated, block})
  end

  @doc """
  Tells `"blocks"` subscribers (the block stream) that a reorg replaced blocks:
  `{:reorg, %{fork_point: height, fork_height: height, orphans: [hash]}}`.
  """
  def broadcast_reorg(%{fork_point: _, fork_height: _, orphans: _} = reorg) do
    Phoenix.PubSub.broadcast(@pubsub, "blocks", {:reorg, reorg})
  end

  @doc """
  Returns the list of blocks with pagination.

  ## Examples

      iex> list_blocks()
      [%Block{}, ...]

      iex> list_blocks(page: 2, per_page: 50)
      [%Block{}, ...]

  """
  def list_blocks(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    offset = (page - 1) * per_page

    query =
      from b in Block,
        order_by: [desc: b.height],
        limit: ^per_page,
        offset: ^offset

    Repo.all(query)
  end

  @doc """
  Returns the total count of blocks.
  """
  def count_blocks do
    Repo.aggregate(Block, :count, :id)
  end

  @doc """
  Gets a single block.

  Raises `Ecto.NoResultsError` if the Block does not exist.

  ## Examples

      iex> get_block!(123)
      %Block{}

      iex> get_block!(456)
      ** (Ecto.NoResultsError)

  """
  # def get_block!(id), do: Repo.get!(Block, id)

  # Find block by ID, height, or hash
  def get_block!(id_or_height_or_hash) when is_integer(id_or_height_or_hash) do
    # Try finding by ID first, then by height
    Repo.get(Block, id_or_height_or_hash) ||
      Repo.one(from b in Block, where: b.height == ^id_or_height_or_hash, limit: 1) ||
      raise Ecto.NoResultsError, queryable: Block
  end

  def get_block!(height_or_hash) when is_binary(height_or_hash) do
    case Integer.parse(height_or_hash) do
      # if passed a height as string, find by height
      {height, ""} ->
        Repo.one(from b in Block, where: b.height == ^height, limit: 1) ||
          raise Ecto.NoResultsError, queryable: Block

      # if passed what is assumed to be a hash, find by hash
      _ ->
        Repo.one(from b in Block, where: b.hash == ^height_or_hash, limit: 1) ||
          raise Ecto.NoResultsError, queryable: Block
    end
  end

  @doc """
  The block at `height`, or nil. Height only: unlike `get_block/1` with an
  integer, it never matches a row's primary key, so sync code that means a
  height always gets that height.
  """
  def get_block_at_height(height) when is_integer(height) do
    Repo.one(from b in Block, where: b.height == ^height, limit: 1)
  end

  @doc "The header time of the block at `height`, or nil. Reads nothing else."
  @spec block_time(integer()) :: integer() | nil
  def block_time(height) when is_integer(height) do
    Repo.one(from b in Block, where: b.height == ^height, select: b.time, limit: 1)
  end

  # An integer is tried as a primary key first, then as a height. Sync code
  # that means a height must use get_block_at_height/1.
  def get_block(id_or_height_or_hash) when is_integer(id_or_height_or_hash) do
    Repo.get(Block, id_or_height_or_hash) ||
      Repo.one(from b in Block, where: b.height == ^id_or_height_or_hash, limit: 1)
  end

  def get_block(height_or_hash) when is_binary(height_or_hash) do
    case Integer.parse(height_or_hash) do
      {height, ""} -> Repo.one(from b in Block, where: b.height == ^height, limit: 1)
      _ -> Repo.one(from b in Block, where: b.hash == ^height_or_hash, limit: 1)
    end
  end

  @doc """
  A block for display, without its txid array, plus how many txids it holds.

  Large blocks carry millions of txids; the detail page reads them a page at
  a time with `block_txids_page/3` instead. `tx` is nil on the returned
  block. Raises `Ecto.NoResultsError` (a 404) when no block matches.
  """
  @spec get_block_for_display!(String.t() | integer()) :: {Block.t(), non_neg_integer()}
  def get_block_for_display!(height_or_hash) do
    fields = Block.__schema__(:fields) -- [:tx]

    query =
      case block_lookup(height_or_hash) do
        {:height, height} -> from(b in Block, where: b.height == ^height)
        {:hash, hash} -> from(b in Block, where: b.hash == ^hash)
      end

    query
    |> limit(1)
    |> select([b], {struct(b, ^fields), fragment("coalesce(cardinality(?), 0)", b.tx)})
    |> Repo.one()
    |> case do
      nil -> raise Ecto.NoResultsError, queryable: Block
      {block, count} -> {%{block | tx: nil}, count}
    end
  end

  defp block_lookup(height) when is_integer(height), do: {:height, height}

  defp block_lookup(height_or_hash) when is_binary(height_or_hash) do
    case Integer.parse(height_or_hash) do
      {height, ""} -> {:height, height}
      _ -> {:hash, height_or_hash}
    end
  end

  @doc """
  One page of a block's txids, sliced in Postgres so the array never leaves
  the database whole. Pages count from 1.
  """
  @spec block_txids_page(integer(), pos_integer(), pos_integer()) :: [String.t()]
  def block_txids_page(block_id, page, page_size) when page >= 1 and page_size >= 1 do
    first = (page - 1) * page_size + 1
    last = page * page_size

    from(b in Block,
      where: b.id == ^block_id,
      select: fragment("?[?:?]", b.tx, type(^first, :integer), type(^last, :integer))
    )
    |> Repo.one()
    |> Kernel.||([])
  end

  @doc """
  Whether every txid of the block (by hash) has a stored transaction, given
  how many txids the block lists.
  """
  @spec block_transactions_downloaded?(String.t(), non_neg_integer()) :: boolean()
  def block_transactions_downloaded?(_hash, 0), do: false

  def block_transactions_downloaded?(hash, expected_count) when is_binary(hash) do
    stored_count =
      Repo.one(from t in Transaction, where: t.block_hash == ^hash, select: count(t.id))

    stored_count == expected_count
  end

  def get_transaction!(id_or_txid) when is_integer(id_or_txid) do
    # Try finding by ID first, then raise if not found
    Repo.get(Transaction, id_or_txid) || raise Ecto.NoResultsError, queryable: Transaction
  end

  def get_transaction!(txid) when is_binary(txid) do
    query = from t in Transaction, where: t.txid == ^txid, limit: 1
    Repo.one(query) || raise Ecto.NoResultsError, queryable: Transaction
  end

  def get_transaction(id_or_txid) when is_integer(id_or_txid) do
    Repo.get(Transaction, id_or_txid)
  end

  def get_transaction(txid) when is_binary(txid) do
    Repo.one(from t in Transaction, where: t.txid == ^txid, limit: 1)
  end

  @doc """
  Gets a transaction by txid, returns nil if not found.
  """
  def get_transaction_by_txid(txid) do
    query =
      from t in Transaction,
        where: t.txid == ^txid,
        limit: 1

    Repo.one(query)
  end

  @doc """
  Gets the latest block (highest block by height).

  Returns nil if no blocks exist in the database.

  ## Examples

      iex> get_latest_block()
      %Block{height: 850000, ...}

      iex> get_latest_block()
      nil
  """
  def get_latest_block do
    query =
      from b in Block,
        order_by: [desc: b.height],
        limit: 1

    Repo.one(query)
  end

  @doc """
  Returns the block height closest to the given UTC datetime.

  Finds the first block at or after the given time.
  Useful for translating date ranges into block height ranges
  (e.g. "show me everything from January 2024" → height 823000..835000).

  ## Examples

      iex> height_at_time(~U[2024-01-01 00:00:00Z])
      {:ok, 823_000}

      iex> height_at_time(~U[2008-01-01 00:00:00Z])
      {:error, :not_found}
  """
  def height_at_time(%DateTime{} = datetime) do
    unix = DateTime.to_unix(datetime)

    query =
      from b in Block,
        where: b.time >= ^unix,
        order_by: [asc: b.time],
        select: b.height,
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      height -> {:ok, height}
    end
  end

  @doc """
  Returns the UTC datetime for a given block height.

  ## Examples

      iex> time_at_height(100_000)
      {:ok, ~U[2012-06-13 11:14:31Z]}

      iex> time_at_height(999_999_999)
      {:error, :not_found}
  """
  def time_at_height(height) when is_integer(height) do
    query =
      from b in Block,
        where: b.height == ^height,
        select: b.time,
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      unix -> {:ok, DateTime.from_unix!(unix)}
    end
  end

  @doc """
  Returns a list of {height, time} pairs for a range, sampled at intervals.

  Used to build time↔height lookup tables for UI scrubbers without
  querying every block. Returns one sample per `step` blocks.

  ## Examples

      iex> height_time_samples(0, 100_000, 10_000)
      [{0, ~U[2009-01-03 18:15:05Z]}, {10000, ~U[2009-02-12 ...Z]}, ...]
  """
  def height_time_samples(start_height, end_height, step \\ 10_000) do
    # Generate the heights we want to sample
    heights =
      start_height
      |> Stream.iterate(&(&1 + step))
      |> Stream.take_while(&(&1 <= end_height))
      |> Enum.to_list()

    query =
      from b in Block,
        where: b.height in ^heights,
        select: {b.height, b.time},
        order_by: [asc: b.height]

    Repo.all(query)
    |> Enum.map(fn {height, unix} -> {height, DateTime.from_unix!(unix)} end)
  end

  @doc """
  Checks if a block exists at the given height.

  ## Examples

      iex> block_exists?(100)
      true

      iex> block_exists?(999999)
      false
  """
  def block_exists?(height) when is_integer(height) do
    query =
      from b in Block,
        where: b.height == ^height,
        select: count(b.id)

    Repo.one(query) > 0
  end

  @doc """
  Checks if a block exists by hash.

  ## Examples

      iex> block_exists_by_hash?("00000000...")
      true
  """
  def block_exists_by_hash?(hash) when is_binary(hash) do
    query =
      from b in Block,
        where: b.hash == ^hash,
        select: count(b.id)

    Repo.one(query) > 0
  end

  @doc """
  Returns a list of heights for existing blocks in a range.
  Useful for skipping already-downloaded blocks during sync.

  ## Examples

      iex> get_existing_block_heights(0, 100)
      [0, 1, 2, 5, 10, 50]
  """
  def get_existing_block_heights(start_height, end_height) do
    query =
      from b in Block,
        where: b.height >= ^start_height and b.height <= ^end_height,
        select: b.height,
        order_by: [asc: b.height]

    Repo.all(query)
  end

  @doc """
  Returns the list of missing block height ranges between `start_height` and `end_height`.

  The result is a list of `{range_start, range_end}` tuples representing contiguous
  gaps with no stored blocks. When all heights are present, the list is empty.

  ## Examples

      iex> missing_block_ranges(0, 5)
      [{0, 2}, {4, 4}]

  """
  def missing_block_ranges(start_height, end_height)
      when is_integer(start_height) and is_integer(end_height) do
    cond do
      start_height > end_height ->
        []

      true ->
        existing = get_existing_block_heights(start_height, end_height)
        build_missing_ranges(existing, start_height, end_height)
    end
  end

  @doc """
  Checks if all transactions for a block have been downloaded.

  Returns true if all txids in the block have corresponding Transaction records.
  """
  def block_transactions_downloaded?(%Block{tx: tx_ids, hash: hash}) when is_list(tx_ids) do
    # Count how many transactions we have for this block
    query =
      from t in Transaction,
        where: t.block_hash == ^hash,
        select: count(t.id)

    stored_count = Repo.one(query)
    expected_count = length(tx_ids)

    stored_count == expected_count && expected_count > 0
  end

  def block_transactions_downloaded?(_), do: false

  @doc """
  Nudges the automatic sync loop, which reaches this block in height order.
  Does not bypass a pause or allocate another worker slot.
  Accepts a Block or a block hash; returns `{:ok, :automatic}`.
  """
  @spec queue_transaction_fetch(Block.t() | String.t()) ::
          {:ok, :automatic} | {:error, :block_not_found}
  def queue_transaction_fetch(%Block{}) do
    # Compatibility for callers of the old per-block enqueuer. Only the
    # coordinator assigns work, in height order and within the shared limit.
    Bitblocks.Sync.Coordinator.ensure_running()
    {:ok, :automatic}
  end

  def queue_transaction_fetch(block_hash) when is_binary(block_hash) do
    case Repo.get_by(Block, hash: block_hash) do
      nil -> {:error, :block_not_found}
      block -> queue_transaction_fetch(block)
    end
  end

  @doc """
  Upgrades a block from header_only to header_synced by fetching transaction IDs.

  This is idempotent - if the block already has txids, it just returns :ok.

  ## Examples

      iex> upgrade_block_to_header_synced(759108)
      {:ok, %Block{sync_state: "header_synced", tx: [...]}}

      iex> upgrade_block_to_header_synced("00000000...")
      {:ok, %Block{sync_state: "header_synced", tx: [...]}}
  """
  def upgrade_block_to_header_synced(height_or_hash) do
    with {:ok, block} <- fetch_block(height_or_hash),
         {:ok, upgraded_block} <- do_upgrade_block_to_header_synced(block) do
      broadcast_block_update(upgraded_block)
      {:ok, upgraded_block}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_block(height) when is_integer(height) do
    case get_block_at_height(height) do
      nil -> {:error, :block_not_found}
      block -> {:ok, block}
    end
  end

  defp fetch_block(hash) when is_binary(hash) do
    case get_block(hash) do
      nil -> {:error, :block_not_found}
      block -> {:ok, block}
    end
  end

  defp do_upgrade_block_to_header_synced(%Block{sync_state: "header_synced"} = block) do
    # Already upgraded
    {:ok, block}
  end

  defp do_upgrade_block_to_header_synced(%Block{sync_state: "completed"} = block) do
    # Already has everything
    {:ok, block}
  end

  defp do_upgrade_block_to_header_synced(%Block{tx: tx} = block)
       when is_list(tx) and length(tx) > 0 do
    # Already has txids, just update state
    block
    |> Ecto.Changeset.change(%{sync_state: "header_synced"})
    |> Repo.update()
  end

  defp do_upgrade_block_to_header_synced(%Block{hash: hash, height: height} = block) do
    require Logger
    Logger.info("Upgrading block #{height} from header_only to header_synced")

    # Fetch transaction IDs using getblock verbosity 1
    case rpc().getblock(hash, 1) do
      block_data when is_map(block_data) ->
        txids = block_data["tx"] || []

        # Memory optimization: Don't store tx array for huge blocks (>10k transactions)
        tx_array_to_store =
          if length(txids) > 10_000 do
            Logger.debug(
              "Block #{height} has #{length(txids)} txs, not storing tx array to save memory"
            )

            []
          else
            txids
          end

        # Update block with transaction IDs. `num_tx` is set from the fetched
        # list — it is the completeness denominator (TxidSource), so it must be
        # correct even when the array itself is dropped for memory.
        block
        |> Ecto.Changeset.change(%{
          tx: tx_array_to_store,
          num_tx: length(txids),
          sync_state: "header_synced",
          # Update other fields that might not have been in header-only mode
          chainwork: Map.get(block_data, "chainwork", block.chainwork),
          difficulty: to_string(Map.get(block_data, "difficulty", block.difficulty)),
          nextblockhash: Map.get(block_data, "nextblockhash", block.nextblockhash),
          size: Map.get(block_data, "size", block.size)
        })
        |> Repo.update()

      {:error, reason} ->
        Logger.error("Failed to upgrade block #{height}: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.error("Unexpected response upgrading block #{height}: #{inspect(other)}")
        {:error, :unexpected_response}
    end
  end

  # Swappable RPC client — tests point this at BitcoinsvCliMock (config/test.exs).
  defp rpc, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)

  @doc """
  Upgrades blocks in a range from header_only to header_synced.

  Fetches transaction IDs for all header_only blocks in the range.
  This is useful for preparing blocks before queuing transaction downloads.

  ## Examples

      iex> upgrade_blocks_to_header_synced(0, 1000)
      {:ok, 150}  # 150 blocks upgraded
  """
  def upgrade_blocks_to_header_synced(start_height, end_height) do
    query =
      from b in Block,
        where: b.height >= ^start_height and b.height <= ^end_height,
        where: b.sync_state == "header_only",
        select: b

    blocks = Repo.all(query)

    results =
      Enum.map(blocks, fn block ->
        do_upgrade_block_to_header_synced(block)
      end)

    successful =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    {:ok, successful}
  end

  @doc """
  Creates a block.

  ## Examples

      iex> create_block(%{field: value})
      {:ok, %Block{}}

      iex> create_block(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_block(attrs \\ %{}) do
    %Block{}
    |> Block.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a block.

  ## Examples

      iex> update_block(block, %{field: new_value})
      {:ok, %Block{}}

      iex> update_block(block, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_block(%Block{} = block, attrs) do
    block
    |> Block.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a block.

  ## Examples

      iex> delete_block(block)
      {:ok, %Block{}}

      iex> delete_block(block)
      {:error, %Ecto.Changeset{}}

  """
  def delete_block(%Block{} = block) do
    Repo.delete(block)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking block changes.

  ## Examples

      iex> change_block(block)
      %Ecto.Changeset{data: %Block{}}

  """
  def change_block(%Block{} = block, attrs \\ %{}) do
    Block.changeset(block, attrs)
  end

  @doc """
  Returns paginated transactions with optional filters.

  ## Examples

      iex> list_transactions_paginated(nil, 50)
      {[%Transaction{}, ...], next_cursor}

      iex> list_transactions_paginated(cursor, 50, %{block_hash: "00000..."})
      {[%Transaction{}, ...], next_cursor}

  Newest confirmation first: rows with a block height, by `(block_height,
  txid)` descending. Ingest order would put a backfilled old block at the
  head; this keyset can't. `transactions_block_height_txid_index` serves it.

  `cursor` is `{block_height, txid}`, or `nil` for the first page. Returns
  `{transactions, next_cursor}`, `next_cursor` a string for
  `decode_tx_cursor/1`, or `nil` when there are no more results.

  """
  def list_transactions_paginated(cursor \\ nil, per_page \\ 50, filters \\ %{}) do
    query =
      from t in Transaction,
        where: not is_nil(t.block_height),
        order_by: [desc: t.block_height, desc: t.txid],
        limit: ^(per_page + 1)

    query =
      case cursor do
        {height, txid} ->
          from(t in query,
            where: fragment("(?, ?) < (?, ?)", t.block_height, t.txid, ^height, ^txid)
          )

        nil ->
          query
      end

    query = apply_transaction_filters(query, filters)

    rows = Repo.all(query)

    if length(rows) > per_page do
      transactions = Enum.take(rows, per_page)
      {transactions, encode_tx_cursor(List.last(transactions))}
    else
      {rows, nil}
    end
  end

  @doc """
  The cursor after `transaction`: `"<block_height>:<txid>"`.
  """
  def encode_tx_cursor(%Transaction{block_height: height, txid: txid}), do: "#{height}:#{txid}"

  @doc """
  Reads a cursor from `encode_tx_cursor/1`. Blank means the first page.
  Anything else, a pre-#35 numeric id cursor included, is `:error`, so a
  stale cursor is refused rather than silently restarting from the head.
  """
  @spec decode_tx_cursor(String.t() | nil) :: {:ok, {integer(), String.t()} | nil} | :error
  def decode_tx_cursor(cursor) when cursor in [nil, ""], do: {:ok, nil}

  def decode_tx_cursor(cursor) when is_binary(cursor) do
    with [height, txid] <- String.split(cursor, ":", parts: 2),
         {height, ""} when height >= 0 and height <= 2_147_483_647 <- Integer.parse(height),
         true <- txid != "" and String.valid?(txid) do
      {:ok, {height, txid}}
    else
      _ -> :error
    end
  end

  def decode_tx_cursor(_cursor), do: :error

  @doc """
  What a page from `list_transactions_paginated/3` covers: `snapshot_height`
  (the block the listing reaches), `indexed_through_height`, and `complete`,
  true only when every block in the range is `completed`. The range is one
  block under a `:block_hash` filter, otherwise genesis to our highest header.
  """
  @spec tx_list_coverage(map()) :: %{
          snapshot_height: integer() | nil,
          indexed_through_height: integer(),
          complete: boolean()
        }
  def tx_list_coverage(filters \\ %{}) do
    %{indexed_through_height: through, tip_height: tip, complete?: complete?} =
      Bitblocks.Chain.Utxos.coverage()

    case Map.get(filters, :block_hash) do
      hash when is_binary(hash) and hash != "" ->
        block = Repo.one(from(b in Block, where: b.hash == ^hash, select: [:height, :sync_state]))

        %{
          snapshot_height: block && block.height,
          indexed_through_height: through,
          complete: match?(%Block{sync_state: "completed"}, block)
        }

      _ ->
        %{snapshot_height: tip, indexed_through_height: through, complete: complete?}
    end
  end

  defp apply_transaction_filters(query, filters) do
    Enum.reduce(filters, query, fn {key, value}, acc ->
      case {key, value} do
        {:block_hash, hash} when is_binary(hash) and hash != "" ->
          from t in acc, where: t.block_hash == ^hash

        {:txid_search, search} when is_binary(search) and search != "" ->
          # A hex prefix, lower case as stored: LIKE reaches the text_pattern_ops
          # index (ILIKE can't), and hex carries no wildcard. Nothing else is a txid.
          if search =~ ~r/\A[0-9a-fA-F]{1,64}\z/ do
            prefix = String.downcase(search) <> "%"
            from t in acc, where: like(t.txid, ^prefix)
          else
            from t in acc, where: false
          end

        {:protocol, protocol} when is_binary(protocol) and protocol != "" ->
          from t in acc, where: fragment("? @> ARRAY[?]::varchar[]", t.protocols, ^protocol)

        {:has_inputs, true} ->
          from t in acc, where: t.input_count > 0

        {:has_outputs, true} ->
          from t in acc, where: t.output_count > 0

        {:min_inputs, min} when is_integer(min) and min > 0 ->
          from t in acc, where: t.input_count >= ^min

        {:min_outputs, min} when is_integer(min) and min > 0 ->
          from t in acc, where: t.output_count >= ^min

        _ ->
          acc
      end
    end)
  end

  @doc """
  Creates a transaction.

  ## Examples

      iex> create_transaction(%{field: value})
      {:ok, %Transaction{}}

      iex> create_transaction(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_transaction(attrs \\ %{}) do
    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a transaction.

  ## Examples

      iex> update_transaction(transaction, %{field: new_value})
      {:ok, %Transaction{}}

      iex> update_transaction(transaction, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_transaction(%Transaction{} = transaction, attrs) do
    transaction
    |> Transaction.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a transaction.

  ## Examples

      iex> delete_transaction(transaction)
      {:ok, %Transaction{}}

      iex> delete_transaction(transaction)
      {:error, %Ecto.Changeset{}}

  """
  def delete_transaction(%Transaction{} = transaction) do
    Repo.delete(transaction)
  end

  defp build_missing_ranges(existing_heights, start_height, end_height) do
    sorted_existing = Enum.sort(existing_heights)
    do_build_missing_ranges(sorted_existing, start_height, end_height, [])
  end

  defp do_build_missing_ranges(_existing, current_height, end_height, acc)
       when current_height > end_height do
    Enum.reverse(acc)
  end

  defp do_build_missing_ranges([], current_height, end_height, acc) do
    Enum.reverse([{current_height, end_height} | acc])
  end

  defp do_build_missing_ranges([next_existing | rest] = existing, current_height, end_height, acc)
       when current_height <= end_height do
    cond do
      current_height == next_existing ->
        do_build_missing_ranges(rest, current_height + 1, end_height, acc)

      current_height < next_existing ->
        missing_end = min(next_existing - 1, end_height)

        do_build_missing_ranges(existing, missing_end + 1, end_height, [
          {current_height, missing_end} | acc
        ])

      true ->
        # In case the existing list contains heights below the current pointer
        do_build_missing_ranges(rest, current_height, end_height, acc)
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking transaction changes.

  ## Examples

      iex> change_transaction(transaction)
      %Ecto.Changeset{data: %Transaction{}}

  """
  def change_transaction(%Transaction{} = transaction, attrs \\ %{}) do
    Transaction.changeset(transaction, attrs)
  end

  @doc """
  Marks all "running" sync jobs as "failed" with a note that they were interrupted.

  This should be called on application startup to clean up jobs that were
  running when the application was stopped or crashed.

  Returns the number of jobs that were marked as failed.

  ## Examples

      iex> cleanup_stale_sync_jobs()
      3  # 3 jobs were marked as failed

  """
  def cleanup_stale_sync_jobs do
    require Logger

    query =
      from s in Bitblocks.Chain.SyncJob,
        where: s.status == "running"

    # Get the count before updating
    count = Repo.aggregate(query, :count, :id)

    if count > 0 do
      Logger.warning(
        "Found #{count} stale sync job(s) in 'running' state. Marking as failed (likely interrupted by restart)."
      )

      # Mark them all as failed
      {updated_count, _} =
        Repo.update_all(query,
          set: [
            status: "failed",
            completed_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          ]
        )

      Logger.info("Marked #{updated_count} stale sync job(s) as failed")
      updated_count
    else
      Logger.debug("No stale sync jobs found")
      0
    end
  end

  @doc """
  Resets blocks stuck in txs_queued/txs_syncing to failed.

  Called on application startup. If a block is mid-sync when the app stops,
  its worker is gone — mark it failed so it can be retried explicitly.
  """
  def recover_orphaned_blocks do
    require Logger

    {count, _} =
      from(b in Block,
        where: b.sync_state in ["txs_queued", "txs_syncing"]
      )
      |> Repo.update_all(
        set: [
          sync_state: "failed",
          tx_sync_error: "orphaned by app restart",
          # update_all skips autogenerated timestamps; chain tiles (#48) find
          # changed blocks by updated_at
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        ]
      )

    if count > 0 do
      Logger.warning(
        "Marked #{count} orphaned block(s) as failed (stuck in txs_queued/txs_syncing at startup)"
      )
    end

    count
  end

  # ---------------------------------------------------------------------------
  # Spend Index — Phase 1 of progressive tx metadata
  # ---------------------------------------------------------------------------

  @doc """
  Returns true if the outpoint (txid, vout) has been spent.

  ## Examples

      iex> output_spent?("abc123...", 0)
      true

      iex> output_spent?("def456...", 1)
      false

  """
  def output_spent?(txid, vout) when is_binary(txid) and is_integer(vout) do
    query =
      from s in Spend,
        where: s.txid == ^txid and s.vout == ^vout,
        select: count(s.id)

    Repo.one(query) > 0
  end

  @doc """
  Returns the spending transaction info for an outpoint, or nil if unspent.

  ## Examples

      iex> get_spending_tx("abc123...", 0)
      %Spend{spending_txid: "xyz...", spending_vin: 0}

      iex> get_spending_tx("def456...", 1)
      nil

  """
  def get_spending_tx(txid, vout) when is_binary(txid) and is_integer(vout) do
    Repo.one(
      from s in Spend,
        where: s.txid == ^txid and s.vout == ^vout,
        limit: 1
    )
  end

  @doc """
  Returns the spend status of every output for a given txid.

  Returns a list of maps: `[%{vout: 0, spent: true, spending_txid: "..."}, ...]`
  Requires knowing the output count for the transaction.
  """
  def output_spend_statuses(txid) when is_binary(txid) do
    case get_transaction(txid) do
      nil ->
        []

      tx ->
        count = tx.output_count || 0

        spends =
          Repo.all(
            from s in Spend,
              where: s.txid == ^txid,
              select: {s.vout, s.spending_txid}
          )
          |> Map.new()

        Enum.map(0..(count - 1), fn vout ->
          case Map.get(spends, vout) do
            nil -> %{vout: vout, spent: false, spending_txid: nil}
            spending_txid -> %{vout: vout, spent: true, spending_txid: spending_txid}
          end
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Read-time facts (docs/TX_PIPELINE.md): computed when read, never stored,
  # because they change as later blocks come in.
  # ---------------------------------------------------------------------------

  @doc """
  Each output of `txid` and whether it is still a UTXO, from the spend index:

      %{
        txid: "...",
        utxo?: true,
        indexed_through_height: 900_000,
        tip_height: 900_000,
        outputs: [
          %{vout: 0, satoshis: 1_000, status: :spent, spent_by: "<txid>", spent_by_vin: 0},
          %{vout: 1, satoshis: 0, status: :unspendable, spent_by: nil, spent_by_vin: nil},
          %{vout: 2, satoshis: 546, status: :unspent, spent_by: nil, spent_by_vin: nil}
        ]
      }

  `:unspendable` is an OP_RETURN output, which no tx can spend. `:unspent`
  is exact: no stored tx spends it and every block through our tip is
  synced. Without that, an output with no recorded spend is `:unknown`
  (see `Bitblocks.Chain.Utxos`). A tx "is a UTXO" (`utxo?`) when any
  output is `:unspent`.

  nil when the tx isn't stored or its raw bytes don't decode.
  """
  @spec output_status(String.t()) :: map() | nil
  def output_status(txid) when is_binary(txid), do: Bitblocks.Chain.Utxos.of_tx(txid)

  # An outpoint list for the collection lookup stays bounded on huge txs.
  @nft_facts_max_outpoints 10_000

  @doc """
  Whether `txid` is an NFT, and whether it is part of a collection:

      %{
        nft?: true,
        inscriptions: [%{vout: 0, content_type: "image/png"}],
        run?: false,
        collections: [
          %{slug: "grand-tardinians", name: "Grand Tardinians", item: "Grand Tardinians 1",
            origin: "<txid>_0", current_outpoint: "<txid>_0", role: :origin}
        ]
      }

  An NFT is a 1Sat inscription output (an `OP_FALSE OP_IF "ord"` envelope;
  a BSV-20/21 token inscription is fungible, so it doesn't count) or a Run
  jig (the tx is tagged `Run`). Collection membership comes from
  `collection_items`, matched on any of the tx's outpoints by origin (`role:
  :origin`, the mint) or current outpoint (`role: :current`, where it is now).

  Two indexed queries: the tx by txid, then `collection_items` by origin and
  current outpoint. nil when the tx isn't stored.
  """
  @spec nft_facts(String.t()) :: map() | nil
  def nft_facts(txid) when is_binary(txid) do
    case Repo.one(from(t in Transaction, where: t.txid == ^txid, select: {t.raw, t.protocols})) do
      nil ->
        nil

      {raw, protocols} ->
        outputs =
          case is_binary(raw) && Bitblocks.Chain.RawTx.parse(raw) do
            {:ok, %BSV.Tx{outputs: outputs}} -> outputs
            _ -> []
          end

        inscriptions =
          for {%BSV.TxOut{script: script}, vout} <- Enum.with_index(outputs),
              {:ok, inscription} <- [Bitblocks.Ordinals.Inscription.parse(script)],
              inscription.content_type != "application/bsv-20",
              do: %{vout: vout, content_type: inscription.content_type}

        run? = "Run" in (protocols || [])

        %{
          nft?: inscriptions != [] or run?,
          inscriptions: inscriptions,
          run?: run?,
          collections: collection_memberships(txid, length(outputs))
        }
    end
  end

  defp collection_memberships(_txid, 0), do: []

  defp collection_memberships(txid, output_count) do
    outpoints =
      for vout <- 0..(min(output_count, @nft_facts_max_outpoints) - 1), do: "#{txid}_#{vout}"

    known = Bitblocks.OrdinalCollections.known()
    known_ids = Map.new(known, fn {slug, id} -> {id, slug} end)

    Repo.all(
      from(i in Bitblocks.OrdinalCollections.Item,
        where: i.origin in ^outpoints or i.current_outpoint in ^outpoints,
        order_by: [asc: i.origin],
        select: {i.collection_id, i.name, i.origin, i.current_outpoint}
      )
    )
    |> Enum.map(fn {cid, item, origin, current} ->
      {slug, name} =
        case known_ids do
          %{^cid => slug} -> {slug, Bitblocks.OrdinalCollections.config_for(cid)[:name] || slug}
          _ -> {cid, cid}
        end

      %{
        slug: slug,
        name: name,
        item: item,
        origin: origin,
        current_outpoint: current,
        role: if(String.starts_with?(origin, txid <> "_"), do: :origin, else: :current)
      }
    end)
  end

  @doc """
  Records spends from a transaction's inputs into the spend index.

  Parses each input's JSON to extract (txid, vout) and records that this
  transaction spent those outpoints. Skips coinbase inputs.

  Returns `{inserted_count, skipped_count}`.
  """
  def record_spends(%Transaction{txid: spending_txid, inputs: inputs})
      when is_binary(spending_txid) and is_list(inputs) do
    entries =
      inputs
      |> Enum.with_index()
      |> Enum.flat_map(fn {input_json, vin} ->
        case Jason.decode(input_json) do
          {:ok, %{"txid" => prev_txid, "vout" => vout}}
          when is_binary(prev_txid) and is_integer(vout) ->
            # Skip coinbase inputs (all-zero txid)
            if String.match?(prev_txid, ~r/^0+$/) do
              []
            else
              [
                %{
                  txid: prev_txid,
                  vout: vout,
                  spending_txid: spending_txid,
                  spending_vin: vin
                }
              ]
            end

          _ ->
            []
        end
      end)

    # One statement for every input (it was one per input). A row already
    # there (the same outpoint) is left alone and counted as existing; the
    # changeset's rule that vout is not negative is kept by the filter.
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    entries = Enum.filter(entries, &(&1.vout >= 0))

    {inserted, _} =
      Repo.insert_all(Spend, Enum.map(entries, &Map.put(&1, :inserted_at, now)),
        on_conflict: :nothing,
        conflict_target: [:txid, :vout]
      )

    if inserted < length(entries), do: replace_orphaned_spends(entries, spending_txid)

    # Bridge to the order book: if any spent outpoint is a listed token UTXO,
    # this transaction is its settlement — mark the listing filled.
    Bitblocks.OrderBook.settle_spent_token_utxos(entries)

    {inserted, length(entries) - inserted}
  end

  def record_spends(_), do: {0, 0}

  # An outpoint is spent once on a chain, so a row here naming another spender
  # is a spend from an orphaned block whose tx `Reorgs.Reconcile` hasn't
  # removed yet, and this one replaces it (#34). A rival still in a stored
  # block keeps its row.
  defp replace_orphaned_spends(entries, spender) do
    txids = Enum.map(entries, & &1.txid)
    vouts = Enum.map(entries, & &1.vout)

    rivals =
      Repo.all(
        from s in Spend,
          where: s.spending_txid != ^spender,
          where:
            fragment(
              "(?, ?) IN (SELECT * FROM unnest(?::varchar[], ?::int[]))",
              s.txid,
              s.vout,
              ^txids,
              ^vouts
            )
      )

    on_chain =
      Repo.all(
        from t in Transaction,
          join: b in Block,
          on: b.hash == t.block_hash,
          where: t.txid in ^Enum.map(rivals, & &1.spending_txid),
          select: t.txid
      )

    replacements = Map.new(entries, &{{&1.txid, &1.vout}, &1})

    for %Spend{} = rival <- rivals, rival.spending_txid not in on_chain do
      entry = Map.fetch!(replacements, {rival.txid, rival.vout})

      rival
      |> Ecto.Changeset.change(spending_txid: spender, spending_vin: entry.spending_vin)
      |> Repo.update!()
    end
  end

  @chained_states ~w(header_synced txs_queued txs_syncing completed)

  @doc """
  Whether each of `transactions` is confirmed as far as this index knows, as
  `%{txid => %{confirmed: boolean, confirmation: status}}` (#34). A tx is
  confirmed only while its `block_hash` is the block stored at its height:

    * `"confirmed"`: that block exists and its txid list has been checked
      against the header (any state from `header_synced` on).
    * `"unverified"`: that block is stored, but nothing has yet tied this tx
      to its header (`header_only`, `pending` or `failed`).
    * `"orphaned"`: no stored block has that hash at that height: a reorg
      replaced it, and `Reorgs.Reconcile` hasn't settled the row yet.

  One query on the unique `blocks.hash`.
  """
  @spec confirmations([Transaction.t()]) :: %{
          String.t() => %{confirmed: boolean(), confirmation: String.t()}
        }
  def confirmations(transactions) do
    hashes = transactions |> Enum.map(& &1.block_hash) |> Enum.uniq()

    blocks =
      Repo.all(
        from b in Block,
          where: b.hash in ^hashes,
          select: {b.hash, {b.height, b.sync_state}}
      )
      |> Map.new()

    Map.new(transactions, fn tx ->
      status =
        case Map.get(blocks, tx.block_hash) do
          nil ->
            "orphaned"

          {height, _state} when tx.block_height not in [nil, height] ->
            "orphaned"

          {_height, state} when state in @chained_states ->
            "confirmed"

          _unverified ->
            "unverified"
        end

      {tx.txid, %{confirmed: status == "confirmed", confirmation: status}}
    end)
  end

  @doc """
  Indexes any BSV-20 / BSV-21 token inscriptions carried by a transaction.

  Only runs when the transaction was tagged `"BSV20"` during `analyze` (an ordinal
  inscription in an output locking script). For each token output, resolves the
  recipient address from the stored output JSON (matching by `vout`) and routes it
  to `Bitblocks.Tokens.index/1` (deploy+mint, transfer, or classic detect-only).

  Idempotent via the instance's `[:txid, :vout]` unique constraint. Returns the
  count of token outputs indexed.
  """
  def index_tokens(%Transaction{protocols: protocols} = tx) when is_list(protocols) do
    if "BSV20" in protocols do
      index_token_outputs(tx)
    else
      0
    end
  end

  def index_tokens(_), do: 0

  @doc """
  Logs the Bitcom `$` commands carried by `tx` and records prefix-ownership
  proofs (see `Bitblocks.Bitcom`).

  A `$ useradd <address>` proves ownership only when the tx's first input was
  spent from `<address>`; a claim from any other address is logged as invalid.
  No-op unless analyze tagged the tx "Bitcom". Returns the number of proofs
  recorded.
  """
  def index_bitcom(%Transaction{} = tx) do
    {:ok, %{proofs: proofs}} = Bitblocks.Bitcom.index(tx)
    proofs
  end

  def index_bitcom(_), do: 0

  defp index_token_outputs(%Transaction{raw: raw} = tx) when is_binary(raw) do
    case Bitblocks.ProtocolParser.token_outputs(raw) do
      {:ok, token_outputs} ->
        addresses = output_addresses_by_vout(tx.outputs)

        indexed =
          Enum.count(token_outputs, fn %{vout: vout, token: token} = output ->
            attrs = %{
              txid: tx.txid,
              vout: vout,
              block_height: tx.block_height,
              block_hash: tx.block_hash,
              # The output JSON names no address for an inscribed script
              # (not a bare P2PKH), so fall back to the lock after the envelope.
              recipient: Map.get(addresses, vout) || output[:owner],
              token: token,
              # Transfers are validated together, once every output is in.
              validate: false
            }

            case Bitblocks.Tokens.index(attrs) do
              {:ok, view} when is_map(view) -> true
              _ -> false
            end
          end)

        if Enum.any?(token_outputs, &(&1.token.op == "transfer")),
          do: Bitblocks.Tokens.validate_tx(tx.txid)

        indexed

      _ ->
        0
    end
  end

  defp index_token_outputs(_), do: 0

  # Map output index -> first address in that output's stored JSON.
  defp output_addresses_by_vout(outputs) when is_list(outputs) do
    outputs
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {output_json, vout}, acc ->
      case Jason.decode(output_json) do
        {:ok, %{"scriptPubKey" => %{"addresses" => [addr | _]}}} when is_binary(addr) ->
          Map.put(acc, vout, addr)

        _ ->
          acc
      end
    end)
  end

  defp output_addresses_by_vout(_), do: %{}

  @doc """
  Bulk-populates the spend index from all existing transactions.

  Processes transactions in batches. Idempotent — uses ON CONFLICT DO NOTHING.
  Returns the total number of spend records inserted.

  ## Examples

      iex> backfill_spend_index(batch_size: 500)
      {:ok, 12345}

  """
  def backfill_spend_index(opts \\ []) do
    require Logger
    batch_size = Keyword.get(opts, :batch_size, 500)

    Logger.info("Starting spend index backfill (batch_size=#{batch_size})")

    total =
      do_backfill_spend_index(0, batch_size, 0)

    Logger.info("Spend index backfill complete: #{total} records inserted")
    {:ok, total}
  end

  defp do_backfill_spend_index(last_id, batch_size, acc) do
    txs =
      Repo.all(
        from t in Transaction,
          where: t.id > ^last_id,
          where: not is_nil(t.inputs),
          where: t.coinbase == false or is_nil(t.coinbase),
          order_by: [asc: t.id],
          limit: ^batch_size,
          select: struct(t, [:id, :txid, :inputs])
      )

    case txs do
      [] ->
        acc

      batch ->
        inserted =
          Enum.reduce(batch, 0, fn tx, count ->
            {n, _} = record_spends(tx)
            count + n
          end)

        new_last_id = List.last(batch).id
        do_backfill_spend_index(new_last_id, batch_size, acc + inserted)
    end
  end

  @doc """
  Total satoshis ever paid to `address` in indexed transactions, spent or not.

  `:min_height` counts only txs confirmed at or above that height
  (unconfirmed txs are then excluded).
  """
  def received_for_address(address, opts \\ []) when is_binary(address) do
    query =
      from t in Transaction,
        where: fragment("? @> ARRAY[?]::varchar[]", t.output_addresses, ^address),
        select: t.outputs

    query =
      case Keyword.get(opts, :min_height) do
        nil -> query
        height -> from t in query, where: t.block_height >= ^height
      end

    query
    |> Repo.all()
    |> Enum.flat_map(& &1)
    |> Enum.sum_by(fn output_json ->
      with {:ok, output} <- Jason.decode(output_json),
           [^address | _] <- get_in(output, ["scriptPubKey", "addresses"]) do
        bsv_to_satoshis(output["value"])
      else
        _ -> 0
      end
    end)
  end

  @doc """
  Transactions whose outputs include the given Electrum-convention scripthash
  (GIN lookup on `output_script_hashes`), newest first.

  This is the script-addressed analog of address history — it works for ANY
  locking script, including custom/covenant scripts that have no address.
  """
  def history_for_script_hash(script_hash) when is_binary(script_hash) do
    Repo.all(
      from t in Transaction,
        where: fragment("? @> ARRAY[?]::varchar[]", t.output_script_hashes, ^script_hash),
        order_by: [desc: t.block_height],
        limit: 1000,
        select: %{txid: t.txid, block_height: t.block_height, block_hash: t.block_hash}
    )
  end

  @doc """
  Transactions carrying any output whose opcode skeleton matches the given
  template hash (GIN lookup on `output_template_hashes`), newest first.
  """
  def history_for_template_hash(template_hash) when is_binary(template_hash) do
    Repo.all(
      from t in Transaction,
        where: fragment("? @> ARRAY[?]::varchar[]", t.output_template_hashes, ^template_hash),
        order_by: [desc: t.block_height],
        limit: 1000,
        select: %{txid: t.txid, block_height: t.block_height, block_hash: t.block_hash}
    )
  end

  @spend_depth_max 100

  @doc """
  Returns the spend depth of a UTXO — the number of hops from the coinbase
  transaction that originally minted the value to the transaction that created
  this output.

  A coinbase output has depth 0.
  An output whose parent transaction directly spent a coinbase has depth 1, etc.

  When a transaction has multiple inputs (from different lineages), the minimum
  parent depth is used — the shortest path to any coinbase ancestor.

  Returns `{:ok, depth}` or `{:error, :max_depth_exceeded}` if the chain exceeds
  #{@spend_depth_max} hops, or `{:error, :not_found}` if the txid is not indexed.
  """
  def spend_depth(txid, _vout \\ 0) when is_binary(txid) do
    do_spend_depth([txid], 0, MapSet.new())
  end

  # BFS level by level. `txids` is the frontier for this level.
  # Fetch all at once, check coinbase, recurse on parents.
  defp do_spend_depth([], _depth, _seen), do: {:error, :not_found}

  defp do_spend_depth(_txids, depth, _seen) when depth > @spend_depth_max,
    do: {:error, :max_depth_exceeded}

  defp do_spend_depth(txids, depth, seen) do
    rows =
      Repo.all(
        from t in Transaction,
          where: t.txid in ^txids,
          select: %{txid: t.txid, coinbase: t.coinbase, input_txids: t.input_txids}
      )

    cond do
      rows == [] ->
        {:error, :not_found}

      Enum.any?(rows, & &1.coinbase) ->
        {:ok, depth}

      true ->
        next_seen = Enum.reduce(rows, seen, fn r, acc -> MapSet.put(acc, r.txid) end)

        parents =
          rows
          |> Enum.flat_map(fn r -> r.input_txids || [] end)
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(next_seen, &1))

        do_spend_depth(parents, depth + 1, next_seen)
    end
  end

  # Converts a BSV float (e.g. 0.00001234) from RPC vout JSON to integer satoshis.
  # RPC value is denominated in BSV; 1 BSV = 100_000_000 satoshis.
  defp bsv_to_satoshis(nil), do: 0
  defp bsv_to_satoshis(value) when is_number(value), do: round(value * 100_000_000)
end
