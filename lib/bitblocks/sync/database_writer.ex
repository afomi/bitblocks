defmodule Bitblocks.Sync.DatabaseWriter do
  @moduledoc """
  GenStage consumer that writes blocks to the database.

  This stage:
  - Receives complete block data from TransactionFetcher stages
  - Writes blocks to the database
  - Can batch writes for efficiency
  - Handles duplicate blocks gracefully
  - Notifies parent of successful writes
  """

  use GenStage
  require Logger
  alias Bitblocks.{Repo, Chain}

  defmodule State do
    defstruct [:parent, :blocks_written]
  end

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    subscribe_to = Keyword.fetch!(opts, :subscribe_to)

    state = %State{
      parent: Keyword.fetch!(opts, :parent),
      blocks_written: 0
    }

    Logger.info("DatabaseWriter initialized")

    {:consumer, state, subscribe_to: subscribe_to}
  end

  @impl true
  def handle_events(events, _from, state) do
    start_time = System.monotonic_time()

    if length(events) > 0 do
      Logger.info("DatabaseWriter: writing #{length(events)} blocks")
    end

    # Write each block to database
    results =
      Enum.map(events, fn block_data ->
        write_block(block_data, state)
      end)

    # Count successes
    {successful_results, _failed} = Bitblocks.RpcHelper.split_ok_error(results)
    successful = length(successful_results)

    # Notify parent of each successful write
    Enum.each(results, fn
      {:ok, height} ->
        send(state.parent, {:block_processed, height})

      {:error, height, error} ->
        send(state.parent, {:block_error, height, error})
    end)

    new_state = %{state | blocks_written: state.blocks_written + successful}

    if length(events) > 0 do
      Logger.info(
        "DatabaseWriter: wrote #{successful}/#{length(events)} blocks (total: #{new_state.blocks_written})"
      )
    end

    # Emit telemetry
    if length(events) > 0 do
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:bitblocks, :sync, :database_writer],
        %{
          duration: duration,
          blocks_written: successful,
          blocks_failed: length(events) - successful
        },
        %{total_blocks: new_state.blocks_written}
      )
    end

    {:noreply, [], new_state}
  end

  # Private Functions

  defp write_block(block_data, _state) do
    height = block_data.height

    try do
      # Use a transaction to write block and optionally its transactions atomically
      Repo.transaction(fn ->
        # Write the block
        # Memory optimization: Don't store tx array for huge blocks (>10k transactions)
        # We store num_tx which is sufficient, and can query transactions table
        tx_list =
          if length(block_data.tx || []) > 10_000 do
            Logger.debug(
              "Block #{height} has #{length(block_data.tx)} txs, not storing tx array to save memory"
            )

            []
          else
            block_data.tx
          end

        block_struct = %Chain.Block{
          hash: block_data.hash,
          num_tx: block_data.num_tx,
          time: block_data.time,
          bits: block_data.bits,
          chainwork: block_data.chainwork,
          difficulty: block_data.difficulty,
          height: height,
          mediantime: block_data.mediantime,
          merkleroot: block_data.merkleroot,
          nextblockhash: block_data.nextblockhash,
          prevblockhash: block_data.prevblockhash,
          nonce: block_data.nonce,
          size: block_data.size,
          version: block_data.version,
          tx: tx_list,
          timestamp: DateTime.from_unix!(block_data.time) |> DateTime.to_naive()
        }

        case Repo.insert(block_struct |> Ecto.Changeset.change(%{sync_state: "header_only"}),
               on_conflict: :nothing
             ) do
          {:ok, block} ->
            # If we have full transaction data, write it directly
            if Map.has_key?(block_data, :transactions) && length(block_data.transactions) > 0 do
              write_transactions(block_data.transactions, block_data.hash)
              # Mark as completed
              Repo.update(Ecto.Changeset.change(block, %{sync_state: "completed"}))
            else
              # Just keep it at header_only - don't auto-queue transaction jobs
              # Transactions can be queued manually later via Chain.queue_transaction_fetch/1
              Logger.debug("DatabaseWriter: stored block header #{height} (header-only sync)")
            end

            Logger.debug("DatabaseWriter: wrote block #{height}")
            height

          {:error, changeset} ->
            Logger.error(
              "DatabaseWriter: failed to write block #{height}: #{inspect(changeset.errors)}"
            )

            Repo.rollback({:block_error, changeset.errors})
        end
      end)
      |> case do
        {:ok, h} -> {:ok, h}
        {:error, error} -> {:error, height, error}
      end
    rescue
      error ->
        Logger.error("DatabaseWriter: exception writing block #{height}: #{inspect(error)}")
        {:error, height, error}
    end
  end

  defp write_transactions(transactions, block_hash) do
    # Write each transaction to the database
    # This is where you can add custom metadata extraction
    Enum.each(transactions, fn tx_data ->
      tx_struct = %Chain.Transaction{
        txid: tx_data.txid,
        raw: tx_data.hex,
        block_hash: block_hash,
        inputs: Enum.map(tx_data.vin, &Jason.encode!/1),
        outputs: Enum.map(tx_data.vout, &Jason.encode!/1)
      }

      # Insert, ignoring conflicts (duplicate txids)
      Repo.insert(tx_struct |> Ecto.Changeset.change(%{}), on_conflict: :nothing)
    end)
  end

  @doc """
  Public function to store transactions from RPC response data.
  Used by both the sync pipeline and background workers.

  Expects transaction data with keys: txid, raw (hex), block_hash, version, inputs, outputs
  """
  def store_transactions(transactions) when is_list(transactions) do
    Enum.each(transactions, fn tx_data ->
      changeset = Chain.Transaction.changeset(%Chain.Transaction{}, tx_data)

      case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :txid) do
        {:ok, tx} ->
          # Replicate to CDN (S3) from the DB record — not the in-flight data.
          # The DB record has been validated by the changeset and is the source of truth.
          Bitblocks.TxCdn.put_transaction_from_db(tx)

        {:error, error} ->
          Logger.error("Failed to store transaction: #{inspect(error)}")
      end
    end)

    {:ok, transactions}
  end
end
