defmodule Bitblocks.Rexxies do
  @moduledoc """
  Rexxie NFT collection — 2,222 unique dinosaur NFTs on BSV via Run protocol.

  Implements the Collections behaviour and loads data from the local
  rexxie-indexer repo (rexxie-collection.json + images/).

  Collection class origin: 12d8ca4bc0eaf26660627cc1671de6a0047246f39f3aa06633f8204223d70cc5
  Minting address: 12nG9uFESfdyE9SdYHVXQeCGFdfYLcdYZG
  """

  use GenServer

  require Logger

  @behaviour Bitblocks.Collections

  @collection_class "12d8ca4bc0eaf26660627cc1671de6a0047246f39f3aa06633f8204223d70cc5"
  @images_dir Path.expand("~/workspace/rexxie-indexer/images")
  @trait_type_list ["background", "base", "body", "eye", "mouth", "head"]

  # ============================================================================
  # Collections behaviour
  # ============================================================================

  @impl Bitblocks.Collections
  def slug, do: "rexxies"

  @impl Bitblocks.Collections
  def name, do: "Rexxies"

  @impl Bitblocks.Collections
  def description,
    do: "2,222 unique dinosaur NFTs on the BSV blockchain, built with Run protocol."

  @impl Bitblocks.Collections
  def trait_types, do: @trait_type_list

  @impl Bitblocks.Collections
  def image_path(item), do: "/images/rexxies/#{item["number"]}.png"

  @impl Bitblocks.Collections
  def item_title(item), do: "Rexxie ##{item["number"]}"

  @impl Bitblocks.Collections
  def metadata do
    %{
      collection_class: @collection_class,
      minting_address: "12nG9uFESfdyE9SdYHVXQeCGFdfYLcdYZG",
      protocol: "Run"
    }
  end

  # ============================================================================
  # GenServer-backed behaviour implementations
  # ============================================================================

  @impl Bitblocks.Collections
  def total_supply do
    GenServer.call(__MODULE__, :total_supply)
  catch
    :exit, _ -> 0
  end

  @impl Bitblocks.Collections
  def list_items(page \\ 1, per_page \\ 50) do
    GenServer.call(__MODULE__, {:list_items, page, per_page})
  catch
    :exit, _ -> {[], 0}
  end

  @impl Bitblocks.Collections
  def get_item(number) do
    GenServer.call(__MODULE__, {:get_item, number})
  catch
    :exit, _ -> nil
  end

  @impl Bitblocks.Collections
  def lookup_txid(txid) when is_binary(txid) do
    GenServer.call(__MODULE__, {:lookup_txid, txid})
  catch
    :exit, _ -> nil
  end

  @impl Bitblocks.Collections
  def all_txids do
    GenServer.call(__MODULE__, :all_txids)
  catch
    :exit, _ -> []
  end

  @impl Bitblocks.Collections
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{}
  end

  @impl Bitblocks.Collections
  def search(query) when is_binary(query) do
    GenServer.call(__MODULE__, {:search, query})
  catch
    :exit, _ -> []
  end

  @impl Bitblocks.Collections
  def filter_trait(type, value) do
    GenServer.call(__MODULE__, {:filter_trait, type, value})
  catch
    :exit, _ -> []
  end

  # ============================================================================
  # Extra public API (Rexxies-specific)
  # ============================================================================

  def collection_class, do: @collection_class
  def images_dir, do: @images_dir

  # ============================================================================
  # GenServer
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :load_collection)
    {:ok, %{nfts: [], by_number: %{}, by_txid: %{}, trait_counts: %{}, loaded: false}}
  end

  @impl true
  def handle_info(:load_collection, state) do
    case load_collection_file() do
      {:ok, nfts} ->
        by_number =
          nfts
          |> Enum.map(fn nft -> {nft["number"], nft} end)
          |> Map.new()

        by_txid =
          nfts
          |> Enum.map(fn nft -> {nft["txid"], nft} end)
          |> Map.new()

        trait_counts = build_trait_counts(nfts)

        Logger.info("Loaded #{length(nfts)} Rexxie NFTs from collection file")

        # Register with the generic Collections system
        Bitblocks.Collections.register("rexxies", __MODULE__)

        {:noreply,
         %{
           nfts: nfts,
           by_number: by_number,
           by_txid: by_txid,
           trait_counts: trait_counts,
           loaded: true
         }}

      {:error, reason} ->
        Logger.warning("Failed to load Rexxie collection: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:lookup_txid, txid}, _from, state) do
    {:reply, Map.get(state.by_txid, txid), state}
  end

  @impl true
  def handle_call({:get_item, number}, _from, state) do
    key = to_string(number)
    {:reply, Map.get(state.by_number, key), state}
  end

  @impl true
  def handle_call({:list_items, page, per_page}, _from, state) do
    offset = (page - 1) * per_page
    page_nfts = Enum.slice(state.nfts, offset, per_page)
    {:reply, {page_nfts, length(state.nfts)}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total: length(state.nfts),
      trait_types: length(@trait_type_list),
      trait_counts: state.trait_counts
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:search, query}, _from, state) do
    q = String.downcase(query)

    results =
      state.nfts
      |> Enum.filter(fn nft ->
        trait_values =
          @trait_type_list
          |> Enum.map(fn t -> String.downcase(nft[t] || "") end)

        Enum.any?(trait_values, fn v -> String.contains?(v, q) end) ||
          String.contains?(String.downcase(nft["number"] || ""), q)
      end)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:filter_trait, type, value}, _from, state) do
    results =
      state.nfts
      |> Enum.filter(fn nft ->
        String.downcase(nft[type] || "") == String.downcase(value)
      end)

    {:reply, results, state}
  end

  @impl true
  def handle_call(:total_supply, _from, state) do
    {:reply, length(state.nfts), state}
  end

  @impl true
  def handle_call(:all_txids, _from, state) do
    txids =
      state.nfts
      |> Enum.map(fn nft -> nft["txid"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {:reply, txids, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp load_collection_file do
    path = collection_json_path()

    if File.exists?(path) do
      with {:ok, contents} <- File.read(path),
           {:ok, data} <- Jason.decode(contents) do
        {:ok, data}
      end
    else
      {:error, {:file_not_found, path}}
    end
  end

  defp collection_json_path do
    Application.get_env(:bitblocks, :rexxie_collection_path) ||
      Path.join(:code.priv_dir(:bitblocks) |> to_string(), "data/rexxie-collection.json")
  end

  defp build_trait_counts(nfts) do
    Enum.reduce(@trait_type_list, %{}, fn type, acc ->
      counts =
        nfts
        |> Enum.map(fn nft -> nft[type] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_v, count} -> -count end)

      Map.put(acc, type, counts)
    end)
  end
end
