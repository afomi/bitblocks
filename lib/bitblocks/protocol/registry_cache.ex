defmodule Bitblocks.Protocol.RegistryCache do
  @moduledoc """
  ETS cache of DB-registered protocol prefixes, so an admin can add a
  PREFIX-ONLY protocol via `Bitblocks.ProtocolRegistry` (one row: address +
  name) without a deploy.

  Detection runs on every transaction during sync, so this layer is strictly
  ETS-lookup-only on the hot path — no DB round-trips per tx. A small
  GenServer owns a public named table holding `{address, name}` pairs for
  ProtocolRegistry rows NOT already covered by the compile-time
  `Bitblocks.Protocol.Handlers` registry (compared by name, so a DB row for
  "MAP" can never shadow the real MAP handler).

  Loading is lazy and tolerant: the table starts empty, an initial load is
  attempted after init, and `refresh/0` reloads on demand. If the DB is
  unavailable or the table is empty (or even missing), `match_name/1` simply
  returns nil and detection falls back to the compile-time handlers alone —
  never crashing or slowing the sync path.

  `Bitblocks.Protocol.Handlers.detect_all/1` consults this cache only for
  segments that matched no compile-time handler.
  """

  use GenServer

  require Logger

  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.Protocol.Handlers

  @table :bitblocks_protocol_registry_cache

  # ── Client API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reloads the cache from the ProtocolRegistry DB.

  Returns `{:ok, count}` with the number of cached prefixes, or
  `{:error, reason}` (leaving the previous table contents intact) when the
  DB is unavailable.
  """
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @doc "Empties the cache (detection falls back to compile-time handlers)."
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  The cached protocol name whose address prefixes `first_chunk`, or nil.

  Exact-match ETS lookup first, then a prefix scan over the (small) table.
  Safe to call even when the cache process isn't running.
  """
  def match_name(first_chunk) when is_binary(first_chunk) do
    case :ets.lookup(@table, first_chunk) do
      [{_address, name} | _] -> name
      [] -> prefix_scan(first_chunk)
    end
  rescue
    # Table not created (process not started) — fall back to compile-time only.
    ArgumentError -> nil
  end

  def match_name(_first_chunk), do: nil

  @doc "All cached `{address, name}` pairs (mainly for introspection/tests)."
  def entries do
    :ets.tab2list(@table)
  rescue
    ArgumentError -> []
  end

  # ── Server callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}, {:continue, :initial_load}}
  end

  @impl true
  def handle_continue(:initial_load, state) do
    # Tolerant: DB may not be reachable yet (or ever, in some test setups);
    # detection just uses the compile-time handlers until a refresh succeeds.
    case load_entries() do
      {:ok, entries} ->
        replace_table(entries)

      {:error, reason} ->
        Logger.debug("Protocol RegistryCache initial load skipped: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    case load_entries() do
      {:ok, entries} ->
        replace_table(entries)
        {:reply, {:ok, length(entries)}, state}

      {:error, reason} = error ->
        Logger.warning("Protocol RegistryCache refresh failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  defp load_entries do
    compiled_names = Handlers.names()

    entries =
      ProtocolRegistry.list_protocols()
      |> Enum.reject(&(&1.name in compiled_names))
      |> Enum.map(&{&1.address, &1.name})

    {:ok, entries}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp replace_table(entries) do
    :ets.delete_all_objects(@table)
    :ets.insert(@table, entries)
    :ok
  end

  defp prefix_scan(first_chunk) do
    :ets.foldl(
      fn {address, name}, acc ->
        acc || if String.starts_with?(first_chunk, address), do: name, else: nil
      end,
      nil,
      @table
    )
  end
end
