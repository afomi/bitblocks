defmodule Bitblocks.Sync.BlockProducer do
  @moduledoc """
  GenStage producer that emits block heights to be synced.

  This stage is responsible for:
  - Fetching block headers (hash, height, metadata)
  - Emitting block info to TransactionFetcher stages
  - Managing demand from downstream consumers

  Block headers are lightweight, so this can run quickly.
  """

  use GenStage
  require Logger

  defmodule State do
    defstruct [
      :start_height,
      :end_height,
      :current_height,
      :parent,
      :pending_demand
    ]
  end

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %State{
      start_height: Keyword.fetch!(opts, :start_height),
      end_height: Keyword.fetch!(opts, :end_height),
      current_height: Keyword.fetch!(opts, :start_height),
      parent: Keyword.fetch!(opts, :parent),
      pending_demand: 0
    }

    Logger.info("BlockProducer initialized: #{state.start_height}..#{state.end_height}")
    {:producer, state}
  end

  @impl true
  def handle_demand(demand, state) do
    Logger.debug("BlockProducer: demand=#{demand}, current=#{state.current_height}")

    total_demand = state.pending_demand + demand
    {events, new_state} = produce_blocks(total_demand, state)

    {:noreply, events, new_state}
  end

  # Private Functions

  defp produce_blocks(demand, state) when state.current_height > state.end_height do
    # No more blocks to produce
    Logger.info("BlockProducer: completed at height #{state.current_height - 1}")
    {:noreply, [], %{state | pending_demand: demand}}
  end

  defp produce_blocks(demand, state) do
    # Calculate how many blocks we can fetch
    remaining = state.end_height - state.current_height + 1
    to_fetch = min(demand, remaining)

    heights = Enum.to_list(state.current_height..(state.current_height + to_fetch - 1))

    # Get list of existing blocks in this range to skip them
    existing =
      Bitblocks.Chain.get_existing_block_heights(
        state.current_height,
        state.current_height + to_fetch - 1
      )

    existing_set = MapSet.new(existing)

    # Filter out already-downloaded blocks
    heights_to_fetch = Enum.reject(heights, fn h -> MapSet.member?(existing_set, h) end)

    if length(existing) > 0 do
      Logger.info(
        "BlockProducer: skipping #{length(existing)} existing blocks in range #{state.current_height}..#{state.current_height + to_fetch - 1}"
      )
    end

    # Fetch block headers (just hash for now, full header could be fetched here)
    events =
      Enum.map(heights_to_fetch, fn height ->
        case BitcoinsvCli.getblockhash(height) do
          hash when is_binary(hash) ->
            {:ok, %{height: height, hash: hash}}

          error ->
            Logger.error("Failed to fetch block hash for height #{height}: #{inspect(error)}")
            {:error, height, error}
        end
      end)

    # Filter out errors and notify parent
    {successful, failed} =
      Enum.split_with(events, fn
        {:ok, _} -> true
        _ -> false
      end)

    Enum.each(failed, fn {:error, height, error} ->
      send(state.parent, {:block_error, height, error})
    end)

    # Extract successful block info
    blocks = Enum.map(successful, fn {:ok, block} -> block end)

    new_height = state.current_height + to_fetch
    remaining_demand = demand - length(blocks)

    Logger.debug("BlockProducer: produced #{length(blocks)} blocks, next_height=#{new_height}")

    {blocks, %{state | current_height: new_height, pending_demand: remaining_demand}}
  end
end
