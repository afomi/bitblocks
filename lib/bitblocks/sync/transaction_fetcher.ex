defmodule Bitblocks.Sync.TransactionFetcher do
  @moduledoc """
  GenStage producer-consumer that fetches full block data including transactions.

  This is the heavy lifting stage that:
  - Receives block info (height, hash) from BlockProducer
  - Fetches full block data with transaction IDs (verbosity 1)
  - Optionally fetches full transaction details (verbosity 2) if needed
  - Emits complete block data to DatabaseWriter

  Multiple instances of this stage run in parallel for concurrency.
  """

  use GenStage
  require Logger

  defmodule State do
    defstruct [:id, :parent]
  end

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    subscribe_to = Keyword.fetch!(opts, :subscribe_to)

    state = %State{
      id: Keyword.get(opts, :id, 1),
      parent: Keyword.fetch!(opts, :parent)
    }

    Logger.info("TransactionFetcher ##{state.id} initialized")

    {:producer_consumer, state, subscribe_to: subscribe_to}
  end

  @impl true
  def handle_events(events, _from, state) do
    Logger.debug("TransactionFetcher ##{state.id}: processing #{length(events)} blocks")

    # Fetch full block data for each block
    enriched_blocks =
      Enum.map(events, fn block_info ->
        fetch_block_with_transactions(block_info, state)
      end)

    # Filter out errors
    {successful, failed} =
      Enum.split_with(enriched_blocks, fn
        {:ok, _} -> true
        _ -> false
      end)

    Enum.each(failed, fn {:error, height, error} ->
      send(state.parent, {:block_error, height, error})
    end)

    blocks = Enum.map(successful, fn {:ok, block} -> block end)

    {:noreply, blocks, state}
  end

  # Private Functions

  defp fetch_block_with_transactions(block_info, state) do
    height = block_info.height
    hash = block_info.hash

    Logger.debug("TransactionFetcher ##{state.id}: fetching block #{height}")

    # Step 1: Get block header with txids (verbosity 1)
    case BitcoinsvCli.getblock(hash, 1) do
      block when is_map(block) ->
        txids = block["tx"] || []

        Logger.debug(
          "TransactionFetcher ##{state.id}: block #{height} has #{length(txids)} transactions"
        )

        # Step 2: Fetch individual transaction details
        # This can be throttled or made optional based on configuration
        fetch_transactions? = Application.get_env(:bitblocks, :fetch_full_transactions, false)

        transactions =
          if fetch_transactions? && length(txids) > 0 do
            fetch_transaction_details(txids, height, state)
          else
            # Just store txids for now
            []
          end

        # Extract and normalize block data
        block_data = %{
          height: height,
          hash: hash,
          num_tx: block["num_tx"],
          time: block["time"],
          bits: block["bits"],
          chainwork: block["chainwork"],
          difficulty: to_string(block["difficulty"]),
          mediantime: block["mediantime"],
          merkleroot: block["merkleroot"],
          nonce: block["nonce"],
          size: block["size"],
          version: block["version"],
          nextblockhash: Map.get(block, "nextblockhash", ""),
          prevblockhash: Map.get(block, "previousblockhash", ""),
          # Array of txids
          tx: txids,
          # Full transaction data (if fetched)
          transactions: transactions
        }

        {:ok, block_data}

      error ->
        Logger.error(
          "TransactionFetcher ##{state.id}: failed to fetch block #{height}: #{inspect(error)}"
        )

        {:error, height, error}
    end
  end

  defp fetch_transaction_details(txids, height, state) do
    Logger.debug(
      "TransactionFetcher ##{state.id}: fetching #{length(txids)} transactions for block #{height}"
    )

    # Fetch each transaction
    # Note: This can be parallelized further if needed using Task.async_stream
    max_tx_fetch = Application.get_env(:bitblocks, :max_transactions_per_block, 1000)
    txids_to_fetch = Enum.take(txids, max_tx_fetch)

    Enum.map(txids_to_fetch, fn txid ->
      case BitcoinsvCli.getrawtransaction(txid, 1) do
        tx when is_map(tx) ->
          %{
            txid: txid,
            version: tx["version"],
            locktime: tx["locktime"],
            size: tx["size"],
            vin: tx["vin"] || [],
            vout: tx["vout"] || [],
            hex: tx["hex"]
          }

        error ->
          Logger.warning(
            "TransactionFetcher ##{state.id}: failed to fetch tx #{txid}: #{inspect(error)}"
          )

          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
