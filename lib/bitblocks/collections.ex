defmodule Bitblocks.Collections do
  @moduledoc """
  Generic collections context.

  Manages NFT/token collections on the BSV blockchain.
  Each collection is backed by a module implementing the collection behaviour,
  which loads items from a local data source (JSON file, DB, etc).

  Collections are registered at startup and provide a uniform API for:
  - Listing and searching items
  - Looking up items by txid (for transaction page integration)
  - Syncing mint transactions from the RPC node
  """

  use GenServer

  require Logger

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a collection module. Called at startup by each collection."
  def register(slug, module) when is_binary(slug) and is_atom(module) do
    GenServer.cast(__MODULE__, {:register, slug, module})
  end

  @doc "List all registered collections."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Get a collection module by slug."
  def get(slug) do
    GenServer.call(__MODULE__, {:get, slug})
  end

  @doc """
  Look up a txid across all registered collections.
  Returns {slug, item} or nil.
  """
  def lookup_txid(txid) when is_binary(txid) do
    GenServer.call(__MODULE__, {:lookup_txid, txid})
  end

  @doc """
  Sync all mint transactions for a collection.
  Fetches raw hex from the RPC node for any txids not already in the DB.
  Idempotent — skips txids that already exist.

  Accepts a slug (looks up via registry) or a module directly.
  """
  def sync_transactions(slug) when is_binary(slug) do
    case get(slug) do
      nil -> {:error, :collection_not_found}
      module -> do_sync_transactions(module)
    end
  end

  def sync_transactions(module) when is_atom(module) do
    do_sync_transactions(module)
  end

  @doc """
  Sync transactions from a list of txids directly.
  Useful in eval/migration contexts where GenServers may not be running.
  """
  def sync_txids(txids) when is_list(txids) do
    do_sync_txids("direct", txids)
  end

  defp do_sync_txids(name, txids) do
    Logger.info("Syncing #{length(txids)} #{name} mint transactions...")

    existing =
      txids
      |> Enum.filter(fn txid ->
        Bitblocks.Chain.get_transaction_by_txid(txid) != nil
      end)
      |> MapSet.new()

    missing = Enum.reject(txids, &MapSet.member?(existing, &1))

    Logger.info("#{name}: #{MapSet.size(existing)} already synced, #{length(missing)} to fetch")

    if missing == [] do
      {:ok, %{synced: 0, skipped: MapSet.size(existing), failed: 0}}
    else
      results =
        missing
        |> Enum.chunk_every(100)
        |> Enum.with_index()
        |> Enum.flat_map(fn {chunk, batch_idx} ->
          Logger.info(
            "#{name}: batch #{batch_idx + 1}/#{ceil(length(missing) / 100)} (#{length(chunk)} txs)"
          )

          results = fetch_and_store_batch(chunk)
          Process.sleep(100)
          results
        end)

      synced = Enum.count(results, &(&1 == :ok))
      failed = Enum.count(results, &(&1 == :error))

      Logger.info(
        "#{name} sync complete: #{synced} synced, #{MapSet.size(existing)} skipped, #{failed} failed"
      )

      {:ok, %{synced: synced, skipped: MapSet.size(existing), failed: failed}}
    end
  end

  def sync_all_transactions do
    list()
    |> Enum.map(fn {slug, _module} ->
      {slug, sync_transactions(slug)}
    end)
  end

  # ============================================================================
  # Behaviour
  # ============================================================================

  @doc "Unique slug for URL routing (e.g. \"rexxies\")"
  @callback slug() :: String.t()

  @doc "Human-readable name (e.g. \"Rexxies\")"
  @callback name() :: String.t()

  @doc "Short description of the collection"
  @callback description() :: String.t()

  @doc "Total number of items"
  @callback total_supply() :: non_neg_integer()

  @doc "Paginated list of items. Returns {items, total_count}."
  @callback list_items(page :: pos_integer(), per_page :: pos_integer()) ::
              {list(map()), non_neg_integer()}

  @doc "Get a single item by its number/id within the collection"
  @callback get_item(number :: term()) :: map() | nil

  @doc "Look up an item by its mint txid. Returns item map or nil."
  @callback lookup_txid(txid :: String.t()) :: map() | nil

  @doc "All known mint txids for syncing"
  @callback all_txids() :: list(String.t())

  @doc "Collection stats (total, trait counts, etc)"
  @callback stats() :: map()

  @doc "Search items by query string"
  @callback search(query :: String.t()) :: list(map())

  @doc "Filter items by a trait type and value"
  @callback filter_trait(type :: String.t(), value :: String.t()) :: list(map())

  @doc "Trait types for this collection (e.g. [\"background\", \"base\", ...])"
  @callback trait_types() :: list(String.t())

  @doc "Image path for an item (relative URL)"
  @callback image_path(item :: map()) :: String.t()

  @doc "Display title for an item"
  @callback item_title(item :: map()) :: String.t()

  @doc "Optional: collection-specific metadata"
  @callback metadata() :: map()

  @optional_callbacks [metadata: 0]

  # ============================================================================
  # GenServer
  # ============================================================================

  @impl true
  def init(_opts) do
    {:ok, %{collections: %{}}}
  end

  @impl true
  def handle_cast({:register, slug, module}, state) do
    Logger.info("Registered collection: #{slug} (#{inspect(module)})")
    {:noreply, put_in(state, [:collections, slug], module)}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Map.to_list(state.collections), state}
  end

  @impl true
  def handle_call({:get, slug}, _from, state) do
    {:reply, Map.get(state.collections, slug), state}
  end

  @impl true
  def handle_call({:lookup_txid, txid}, _from, state) do
    result =
      Enum.find_value(state.collections, fn {slug, module} ->
        case module.lookup_txid(txid) do
          nil -> nil
          item -> {slug, item}
        end
      end)

    {:reply, result, state}
  end

  # ============================================================================
  # Transaction Sync (generic, idempotent)
  # ============================================================================

  defp do_sync_transactions(module) do
    txids = module.all_txids()
    do_sync_txids(module.name(), txids)
  end

  defp fetch_and_store_batch(txids) do
    case BitcoinsvCli.batch_getrawtransaction(txids, 1) do
      {:ok, tx_map} ->
        Enum.map(txids, fn txid ->
          case Map.get(tx_map, txid) do
            {:error, error} ->
              Logger.warning("Failed to fetch tx #{txid}: #{inspect(error)}")
              :error

            tx_data when is_map(tx_data) ->
              store_transaction(tx_data)

            nil ->
              Logger.warning("No data returned for tx #{txid}")
              :error
          end
        end)

      {:error, reason} ->
        Logger.warning("Batch RPC failed, falling back to individual calls: #{inspect(reason)}")

        Enum.map(txids, fn txid ->
          case BitcoinsvCli.getrawtransaction(txid, 1) do
            tx_data when is_map(tx_data) ->
              store_transaction(tx_data)

            error ->
              Logger.warning("Failed to fetch tx #{txid}: #{inspect(error)}")
              :error
          end
        end)
    end
  end

  defp store_transaction(tx_data) do
    txid = tx_data["txid"]
    raw = tx_data["hex"]
    block_hash = tx_data["blockhash"]

    total_input_satoshis =
      (tx_data["vin"] || [])
      |> Enum.reduce(0, fn input, acc ->
        if Map.has_key?(input, "coinbase"),
          do: acc,
          else: acc + trunc(Map.get(input, "value", 0) * 100_000_000)
      end)

    total_output_satoshis =
      (tx_data["vout"] || [])
      |> Enum.reduce(0, fn output, acc ->
        acc + trunc(Map.get(output, "value", 0) * 100_000_000)
      end)

    {input_count, output_count} =
      case BSV.Tx.from_binary(raw, encoding: :hex) do
        {:ok, decoded_tx} -> {length(decoded_tx.inputs), length(decoded_tx.outputs)}
        {:error, _} -> {0, 0}
      end

    t = %Bitblocks.Chain.Transaction{
      txid: txid,
      raw: raw,
      block_hash: block_hash,
      inputs: ["tx.inputs"],
      outputs: ["tx.outputs"],
      total_input_satoshis: total_input_satoshis,
      total_output_satoshis: total_output_satoshis,
      input_count: input_count,
      output_count: output_count
    }

    case Bitblocks.Repo.insert(
           Ecto.Changeset.change(t, %{}),
           on_conflict: :nothing,
           conflict_target: :txid
         ) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed inserting tx #{txid}: #{inspect(changeset.errors)}")
        :error
    end
  end
end
