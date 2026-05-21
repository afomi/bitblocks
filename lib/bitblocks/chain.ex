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
  Returns blocks that are actively syncing transactions, with download progress.

  Returns a list of maps with block info and the count of transactions
  already downloaded vs total expected.
  """
  def blocks_syncing_transactions do
    from(b in Block,
      where: b.sync_state in ["txs_queued", "txs_syncing"],
      left_join: t in Transaction,
      on: t.block_hash == b.hash,
      group_by: [b.id, b.hash, b.height, b.num_tx, b.sync_state, b.tx_sync_started_at],
      select: %{
        hash: b.hash,
        height: b.height,
        num_tx: b.num_tx,
        sync_state: b.sync_state,
        tx_sync_started_at: b.tx_sync_started_at,
        downloaded: count(t.id)
      },
      order_by: [asc: b.height]
    )
    |> Repo.all()
  end

  @doc """
  Queues an Oban job to fetch transactions for a block.

  Accepts a Block struct and updates its sync_state to "txs_queued" before
  enqueueing the job. Works regardless of the block's current sync_state
  (useful for retries).

  ## Examples

      iex> queue_transaction_fetch("00000000...")
      {:ok, %Oban.Job{}}

      iex> queue_transaction_fetch(block)
      {:ok, %Oban.Job{}}
  """
  def queue_transaction_fetch(%Block{hash: hash} = block) do
    # Update block to txs_queued state (works for any current state)
    {:ok, updated_block} =
      block
      |> Ecto.Changeset.change(%{sync_state: "txs_queued"})
      |> Repo.update()

    broadcast_block_update(updated_block)

    # Enqueue job
    %{block_hash: hash}
    |> Bitblocks.Workers.FetchTransactionsWorker.new()
    |> Oban.insert()
  end

  def queue_transaction_fetch(block_hash) when is_binary(block_hash) do
    case Repo.get_by(Block, hash: block_hash) do
      nil -> {:error, :block_not_found}
      block -> queue_transaction_fetch(block)
    end
  end

  @doc """
  Queues transaction fetch jobs for all blocks in a given state.

  ## Examples

      iex> queue_transaction_fetch_for_state("header_synced")
      {:ok, 150}  # 150 jobs queued
  """
  def queue_transaction_fetch_for_state(state \\ "header_synced") do
    query =
      from b in Block,
        where: b.sync_state == ^state,
        select: b

    blocks = Repo.all(query)

    results = Enum.map(blocks, &queue_transaction_fetch/1)

    {successful_results, failed_results} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    successful = length(successful_results)

    case failed_results do
      [] ->
        {:ok, successful}

      [{:error, reason} | _] ->
        {:error, reason}

      [other | _] ->
        {:error, other}
    end
  end

  @doc """
  Queues transaction fetch jobs for a range of block heights.

  Finds blocks that need transactions (by sync_state) and queues Oban jobs
  in batches of 200 to avoid loading the full range into memory.

  ## Examples

      iex> queue_transaction_fetch_for_range(0, 1000)
      {:ok, 150}
  """
  def queue_transaction_fetch_for_range(start_height, end_height) do
    batch_size = 200

    do_queue_tx_range(start_height, end_height, batch_size, 0)
  end

  defp do_queue_tx_range(start_height, end_height, batch_size, acc) do
    # Only fetch blocks that actually need transactions.
    # "completed" and "txs_syncing" blocks are excluded.
    # "txs_queued" blocks are also excluded — they already have a pending job.
    # "failed" blocks ARE included so they can be retried.
    needs_tx_states = ["header_only", "header_synced", "pending", "failed"]

    blocks =
      from(b in Block,
        where: b.height >= ^start_height and b.height <= ^end_height,
        where: b.sync_state in ^needs_tx_states,
        order_by: [asc: b.height],
        limit: ^batch_size
      )
      |> Repo.all()

    if blocks == [] do
      {:ok, acc}
    else
      results = Enum.map(blocks, &queue_transaction_fetch/1)

      successful =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      # Next batch starts after the last block we just processed
      next_start = List.last(blocks).height + 1
      do_queue_tx_range(next_start, end_height, batch_size, acc + successful)
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
    case get_block(height) do
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
    case BitcoinsvCli.getblock(hash, 1) do
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

        # Update block with transaction IDs
        block
        |> Ecto.Changeset.change(%{
          tx: tx_array_to_store,
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

  Cursor is the last `id` seen. Pass `nil` for the first page.
  Returns `{transactions, next_cursor}` where `next_cursor` is `nil` when
  there are no more results.

  """
  def list_transactions_paginated(cursor \\ nil, per_page \\ 50, filters \\ %{}) do
    query =
      from t in Transaction,
        order_by: [desc: t.id],
        limit: ^(per_page + 1)

    query = if cursor, do: from(t in query, where: t.id < ^cursor), else: query
    query = apply_transaction_filters(query, filters)

    rows = Repo.all(query)

    if length(rows) > per_page do
      transactions = Enum.take(rows, per_page)
      next_cursor = List.last(transactions).id
      {transactions, next_cursor}
    else
      {rows, nil}
    end
  end

  defp apply_transaction_filters(query, filters) do
    Enum.reduce(filters, query, fn {key, value}, acc ->
      case {key, value} do
        {:block_hash, hash} when is_binary(hash) and hash != "" ->
          from t in acc, where: t.block_hash == ^hash

        {:txid_search, search} when is_binary(search) and search != "" ->
          # Prefix match only — leading wildcard prevents index use
          from t in acc, where: ilike(t.txid, ^"#{search}%")

        {:protocol, protocol} when is_binary(protocol) and protocol != "" ->
          from t in acc, where: ^protocol == fragment("ANY(?)", t.protocols)

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
          tx_sync_error: "orphaned by app restart"
        ]
      )

    if count > 0 do
      Logger.warning("Marked #{count} orphaned block(s) as failed (stuck in txs_queued/txs_syncing at startup)")
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
              [%{
                txid: prev_txid,
                vout: vout,
                spending_txid: spending_txid,
                spending_vin: vin
              }]
            end

          _ ->
            []
        end
      end)

    inserted =
      Enum.count(entries, fn entry ->
        case %Spend{}
             |> Spend.changeset(entry)
             |> Repo.insert(
               on_conflict: :nothing,
               conflict_target: [:txid, :vout]
             ) do
          {:ok, %{id: nil}} -> false
          {:ok, _} -> true
          _ -> false
        end
      end)

    {inserted, length(entries) - inserted}
  end

  def record_spends(_), do: {0, 0}

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
end
