defmodule Bitblocks.EtsHelper do
  @moduledoc """
  Helper utilities for ETS table management.

  Provides consistent patterns for creating and managing ETS tables across the application.
  """

  @doc """
  Ensures an ETS table exists, creating it if necessary.

  If the table already exists, does nothing. If it doesn't exist, creates it with
  the specified options.

  ## Parameters

  - `table_name` - Atom name for the ETS table
  - `opts` - Keyword list of ETS options (default: [:set, :public, :named_table])

  ## Examples

      iex> ensure_table_exists(:my_cache)
      :ok

      iex> ensure_table_exists(:my_cache, [:bag, :public, :named_table])
      :ok

  ## Returns

  - `:ok` if table exists or was created successfully
  - `{:error, reason}` if table creation failed

  """
  def ensure_table_exists(table_name, opts \\ [:set, :public, :named_table]) do
    if table_exists?(table_name) do
      :ok
    else
      create_table(table_name, opts)
    end
  end

  @doc """
  Checks if an ETS table exists.

  ## Examples

      iex> table_exists?(:my_cache)
      true

      iex> table_exists?(:nonexistent_table)
      false

  """
  def table_exists?(table_name) do
    :ets.whereis(table_name) != :undefined
  end

  @doc """
  Creates an ETS table with the given name and options.

  ## Examples

      iex> create_table(:my_cache)
      :ok

      iex> create_table(:my_cache, [:bag, :public, :named_table])
      :ok

  """
  def create_table(table_name, opts \\ [:set, :public, :named_table]) do
    try do
      :ets.new(table_name, opts)
      :ok
    rescue
      ArgumentError -> {:error, :table_already_exists}
    end
  end

  @doc """
  Safely deletes an ETS table if it exists.

  ## Examples

      iex> delete_table(:my_cache)
      :ok

      iex> delete_table(:nonexistent_table)
      :ok

  """
  def delete_table(table_name) do
    if table_exists?(table_name) do
      :ets.delete(table_name)
    end

    :ok
  end

  @doc """
  Gets a value from an ETS table with a default fallback.

  ## Examples

      iex> get(:my_cache, :key, :default_value)
      :default_value

      iex> :ets.insert(:my_cache, {:key, :value})
      iex> get(:my_cache, :key, :default_value)
      :value

  """
  def get(table_name, key, default \\ nil) do
    case :ets.lookup(table_name, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  @doc """
  Puts a value into an ETS table.

  ## Examples

      iex> put(:my_cache, :key, :value)
      :ok

  """
  def put(table_name, key, value) do
    :ets.insert(table_name, {key, value})
    :ok
  end

  @doc """
  Fetches a value from cache, computing it if missing.

  If the key exists in the table, returns the cached value.
  If the key doesn't exist, executes the computer function, stores the result,
  and returns it.

  ## Examples

      iex> fetch_or_compute(:my_cache, :expensive_key, fn ->
      ...>   # expensive computation
      ...>   :computed_value
      ...> end)
      :computed_value

      # Second call returns cached value without recomputing
      iex> fetch_or_compute(:my_cache, :expensive_key, fn ->
      ...>   # This won't be called
      ...>   :computed_value
      ...> end)
      :computed_value

  """
  def fetch_or_compute(table_name, key, computer) when is_function(computer, 0) do
    case :ets.lookup(table_name, key) do
      [{^key, value}] ->
        value

      [] ->
        value = computer.()
        :ets.insert(table_name, {key, value})
        value
    end
  end

  @doc """
  Fetches a value from cache with TTL support.

  Similar to fetch_or_compute but includes a timestamp. If the cached value
  is older than ttl_seconds, recomputes it.

  ## Parameters

  - `table_name` - Name of the ETS table
  - `key` - Cache key
  - `ttl_seconds` - Time to live in seconds
  - `computer` - Function to compute the value if cache miss or expired

  ## Examples

      iex> fetch_with_ttl(:my_cache, :data, 60, fn ->
      ...>   fetch_from_api()
      ...> end)
      "fresh data"

  """
  def fetch_with_ttl(table_name, key, ttl_seconds, computer) when is_function(computer, 0) do
    now = System.system_time(:second)

    case :ets.lookup(table_name, key) do
      [{^key, {value, timestamp}}] when now - timestamp < ttl_seconds ->
        value

      _ ->
        value = computer.()
        :ets.insert(table_name, {key, {value, now}})
        value
    end
  end

  @doc """
  Clears all entries from an ETS table.

  ## Examples

      iex> clear(:my_cache)
      :ok

  """
  def clear(table_name) do
    :ets.delete_all_objects(table_name)
    :ok
  end

  @doc """
  Gets the number of entries in an ETS table.

  ## Examples

      iex> size(:my_cache)
      42

  """
  def size(table_name) do
    :ets.info(table_name, :size)
  end
end
