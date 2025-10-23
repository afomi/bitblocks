defmodule Bitblocks.RpcHelper do
  @moduledoc """
  Helper utilities for processing Bitcoin RPC batch results and handling fallbacks.

  Provides consistent error handling and fallback strategies for batch RPC operations.
  """

  require Logger

  @doc """
  Processes batch RPC results and extracts successful values.

  Converts a map of `{id, result}` or `{id, {:error, reason}}` into a list of
  successful results, filtering out errors.

  ## Examples

      iex> results = %{0 => "hash1", 1 => {:error, "not found"}, 2 => "hash3"}
      iex> extract_successful_results(results)
      %{0 => "hash1", 2 => "hash3"}

  """
  def extract_successful_results(batch_results) when is_map(batch_results) do
    batch_results
    |> Enum.reject(fn {_id, result} -> match?({:error, _}, result) end)
    |> Map.new()
  end

  @doc """
  Processes batch results with a mapper function, handling errors gracefully.

  For each ID in the list, looks up the result in the batch results map and
  applies the mapper function. If the result is an error or missing, applies
  the error_handler function instead.

  ## Examples

      iex> ids = [0, 1, 2]
      iex> results = %{0 => "hash1", 1 => {:error, "fail"}, 2 => "hash3"}
      iex> mapper = fn id, hash -> {:ok, %{height: id, hash: hash}} end
      iex> error_handler = fn id, error -> {:error, id, error} end
      iex> process_batch_results(ids, results, mapper, error_handler)
      [
        {:ok, %{height: 0, hash: "hash1"}},
        {:error, 1, "fail"},
        {:ok, %{height: 2, hash: "hash3"}}
      ]

  """
  def process_batch_results(ids, batch_results, mapper, error_handler)
      when is_list(ids) and is_map(batch_results) do
    Enum.map(ids, fn id ->
      case Map.get(batch_results, id) do
        {:error, error} ->
          error_handler.(id, error)

        nil ->
          error_handler.(id, :missing_from_batch)

        result ->
          mapper.(id, result)
      end
    end)
  end

  @doc """
  Executes a batch RPC call with automatic fallback to individual calls on failure.

  If the batch call fails, automatically falls back to making individual RPC calls
  for each item. This provides resilience against temporary batch API issues while
  maintaining performance when batch works.

  ## Parameters

  - `items` - List of items to process (e.g., heights, hashes)
  - `batch_fn` - Function that takes the list of items and returns `{:ok, results}` or `{:error, reason}`
  - `single_fn` - Function that takes a single item and returns a result or error
  - `opts` - Options:
    - `:log_fallback` - Whether to log when falling back (default: true)
    - `:fallback_message` - Custom message for fallback log

  ## Examples

      iex> batch_fn = fn heights -> BitcoinsvCli.batch_getblockhash(heights) end
      iex> single_fn = fn height -> BitcoinsvCli.getblockhash(height) end
      iex> batch_with_fallback([0, 1, 2], batch_fn, single_fn)
      [hash0, hash1, hash2]

  """
  def batch_with_fallback(items, batch_fn, single_fn, opts \\ []) do
    log_fallback = Keyword.get(opts, :log_fallback, true)
    fallback_message = Keyword.get(opts, :fallback_message, "Batch RPC failed, falling back to individual requests")

    case batch_fn.(items) do
      {:ok, results} ->
        results

      {:error, reason} ->
        if log_fallback do
          Logger.warning("#{fallback_message}: #{inspect(reason)}")
        end

        # Fallback to individual calls
        items
        |> Enum.map(single_fn)
    end
  end

  @doc """
  Splits a list of results into successful and failed results.

  Returns `{successful, failed}` tuple where successful contains all `{:ok, value}`
  results and failed contains all `{:error, ...}` results.

  ## Examples

      iex> results = [{:ok, 1}, {:error, :bad}, {:ok, 2}, {:error, :worse}]
      iex> split_ok_error(results)
      {[{:ok, 1}, {:ok, 2}], [{:error, :bad}, {:error, :worse}]}

  """
  def split_ok_error(results) do
    Enum.split_with(results, fn
      {:ok, _} -> true
      _ -> false
    end)
  end

  @doc """
  Extracts values from a list of `{:ok, value}` tuples.

  ## Examples

      iex> successful = [{:ok, 1}, {:ok, 2}, {:ok, 3}]
      iex> extract_ok_values(successful)
      [1, 2, 3]

  """
  def extract_ok_values(successful) do
    Enum.map(successful, fn {:ok, value} -> value end)
  end

  @doc """
  Combines split_ok_error and extract_ok_values into a single operation.

  Returns `{values, errors}` where values is a list of unwrapped values from
  successful results and errors is the list of error tuples.

  ## Examples

      iex> results = [{:ok, 1}, {:error, :bad}, {:ok, 2}]
      iex> unwrap_results(results)
      {[1, 2], [{:error, :bad}]}

  """
  def unwrap_results(results) do
    {successful, failed} = split_ok_error(results)
    {extract_ok_values(successful), failed}
  end
end
