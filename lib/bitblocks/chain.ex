defmodule Bitblocks.Chain do
  @moduledoc """
  The Chain context.
  """

  import Ecto.Query, warn: false
  alias Bitblocks.Repo

  alias Bitblocks.Chain.Block
  alias Bitblocks.Chain.Transaction

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

  def get_block(id_or_height_or_hash) do
    try do
      get_block!(id_or_height_or_hash)
    rescue
      Ecto.NoResultsError ->
        nil
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
  Queues an Oban job to fetch transactions for a block.

  ## Examples

      iex> queue_transaction_fetch("00000000...")
      {:ok, %Oban.Job{}}

      iex> queue_transaction_fetch(block)
      {:ok, %Oban.Job{}}
  """
  def queue_transaction_fetch(%Block{hash: hash, sync_state: "header_synced"} = block) do
    # Update block to txs_queued state
    {:ok, _block} =
      block
      |> Ecto.Changeset.change(%{sync_state: "txs_queued"})
      |> Repo.update()

    # Enqueue job
    %{block_hash: hash}
    |> Bitblocks.Workers.FetchTransactionsWorker.new()
    |> Oban.insert()
  end

  def queue_transaction_fetch(%Block{hash: hash} = block) do
    # Allow queuing even if not in header_synced state (for retries)
    # Update block to txs_queued state
    {:ok, _block} =
      block
      |> Ecto.Changeset.change(%{sync_state: "txs_queued"})
      |> Repo.update()

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

  Queues jobs for blocks that don't already have all their transactions downloaded.
  Checks blocks in "header_synced", "pending", or "completed" state and verifies
  if they actually have their transactions.

  ## Examples

      iex> queue_transaction_fetch_for_range(0, 1000)
      {:ok, 1001}
  """
  def queue_transaction_fetch_for_range(start_height, end_height) do
    query =
      from b in Block,
        where: b.height >= ^start_height and b.height <= ^end_height,
        select: b

    blocks = Repo.all(query)

    # Filter out blocks that already have all transactions downloaded
    blocks_needing_txs = Enum.reject(blocks, &block_transactions_downloaded?/1)

    results = Enum.map(blocks_needing_txs, &queue_transaction_fetch/1)

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
  Returns the list of transactions.

  ## Examples

      iex> list_transactions()
      [%Transaction{}, ...]

  """
  def list_transactions do
    query = from b in Transaction, limit: 500
    Repo.all(query)
  end

  @doc """
  Returns paginated transactions with optional filters.

  ## Examples

      iex> list_transactions_paginated(1, 500)
      [%Transaction{}, ...]

      iex> list_transactions_paginated(1, 500, %{block_hash: "00000..."})
      [%Transaction{}, ...]

  """
  def list_transactions_paginated(page \\ 1, per_page \\ 500, filters \\ %{}) do
    offset = (page - 1) * per_page

    query =
      from t in Transaction,
        order_by: [desc: t.id],
        limit: ^per_page,
        offset: ^offset

    query = apply_transaction_filters(query, filters)

    Repo.all(query)
  end

  defp apply_transaction_filters(query, filters) do
    Enum.reduce(filters, query, fn {key, value}, acc ->
      case {key, value} do
        {:block_hash, hash} when is_binary(hash) and hash != "" ->
          from t in acc, where: t.block_hash == ^hash

        {:txid_search, search} when is_binary(search) and search != "" ->
          like_pattern = "%#{search}%"
          from t in acc, where: ilike(t.txid, ^like_pattern)

        {:has_inputs, true} ->
          from t in acc, where: fragment("cardinality(?) > 0", t.inputs)

        {:has_outputs, true} ->
          from t in acc, where: fragment("cardinality(?) > 0", t.outputs)

        {:min_inputs, min} when is_integer(min) and min > 0 ->
          from t in acc, where: fragment("cardinality(?) >= ?", t.inputs, ^min)

        {:min_outputs, min} when is_integer(min) and min > 0 ->
          from t in acc, where: fragment("cardinality(?) >= ?", t.outputs, ^min)

        _ ->
          acc
      end
    end)
  end

  @doc """
  Returns the total count of transactions with optional filters.

  ## Examples

      iex> count_transactions()
      1234

      iex> count_transactions(%{block_hash: "00000..."})
      50

  """
  def count_transactions(filters \\ %{}) do
    query = from t in Transaction
    query = apply_transaction_filters(query, filters)
    Repo.aggregate(query, :count, :id)
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
end
