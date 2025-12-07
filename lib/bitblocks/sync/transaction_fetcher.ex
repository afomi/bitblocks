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
    if events == [] do
      {:noreply, [], state}
    else
      start_time = System.monotonic_time()
      started_at = DateTime.utc_now()
      heights = Enum.map(events, & &1.height)

      send(state.parent, {:fetcher_started, state.id, heights, started_at})

      Logger.debug("TransactionFetcher ##{state.id}: processing #{length(events)} blocks")

      # Fetch full block data for each block
      enriched_blocks =
        Enum.map(events, fn block_info ->
          fetch_block_with_transactions(block_info, state)
        end)

      # Filter out errors
      {successful, failed} = Bitblocks.RpcHelper.split_ok_error(enriched_blocks)

      Enum.each(failed, fn {:error, height, error} ->
        send(state.parent, {:block_error, height, error})
      end)

      blocks = Bitblocks.RpcHelper.extract_ok_values(successful)

      duration_ms =
        System.monotonic_time()
        |> Kernel.-(start_time)
        |> System.convert_time_unit(:native, :millisecond)

      send(
        state.parent,
        {:fetcher_finished, state.id, heights, started_at, duration_ms, length(blocks),
         length(events) - length(blocks)}
      )

      {:noreply, blocks, state}
    end
  end

  # Private Functions

  defp fetch_block_with_transactions(block_info, state) do
    height = block_info.height
    hash = block_info.hash
    start_time = System.monotonic_time()

    Logger.debug("TransactionFetcher ##{state.id}: fetching block #{height}")

    # Use getblockheader instead of getblock for efficiency
    # This is ~5,750,000x smaller for blocks with millions of transactions
    # Returns ~400 bytes of header data instead of up to 2.3 GB
    case BitcoinsvCli.getblockheader(hash, true) do
      header when is_map(header) ->
        num_tx = header["num_tx"] || header["nTx"] || 0

        Logger.debug(
          "TransactionFetcher ##{state.id}: block #{height} has #{num_tx} transactions"
        )

        # Extract and normalize block header data
        block_data = %{
          height: height,
          hash: hash,
          num_tx: num_tx,
          time: header["time"],
          bits: header["bits"],
          chainwork: Map.get(header, "chainwork", ""),
          difficulty: to_string(Map.get(header, "difficulty", "")),
          mediantime: Map.get(header, "mediantime", header["time"]),
          merkleroot: header["merkleroot"],
          nonce: header["nonce"],
          size: nil,
          version: header["version"],
          nextblockhash: Map.get(header, "nextblockhash", ""),
          prevblockhash: header["previousblockhash"] || "",
          # Empty tx array for header-only mode
          tx: [],
          # No transaction data in header-only mode
          transactions: []
        }

        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:bitblocks, :sync, :transaction_fetch],
          %{duration: duration, tx_count: num_tx},
          %{mode: :pipeline, status: :success, height: height, fetcher_id: state.id}
        )

        {:ok, block_data}

      error ->
        duration = System.monotonic_time() - start_time

        Logger.error(
          "TransactionFetcher ##{state.id}: failed to fetch block #{height}: #{inspect(error)}"
        )

        :telemetry.execute(
          [:bitblocks, :sync, :transaction_fetch],
          %{duration: duration, tx_count: 0},
          %{
            mode: :pipeline,
            status: :error,
            height: height,
            fetcher_id: state.id,
            error: inspect(error)
          }
        )

        {:error, height, error}
    end
  end

  # NOTE: This function is currently unused as we're using header-only sync mode
  # It can be re-enabled if we want to fetch full transaction data during parallel sync
  # by setting fetch_full_transactions: true in config
  defp fetch_transaction_details(txids, height, state) do
    Logger.debug(
      "TransactionFetcher ##{state.id}: fetching #{length(txids)} transactions for block #{height}"
    )

    # Fetch each transaction
    # Note: This can be parallelized further if needed using Task.async_stream
    max_tx_fetch = Bitblocks.Config.max_transactions_per_block()
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
