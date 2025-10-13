defmodule Bitblocks.Workers.FetchTransactionsWorker do
  @moduledoc """
  Oban worker for fetching transaction details for a block.

  This worker:
  1. Receives a block ID/hash
  2. Fetches all transaction details from Bitcoin RPC
  3. Stores transactions in the database
  4. Updates block state using the Machinery state machine
  """

  use Oban.Worker,
    queue: :transactions,
    max_attempts: 3,
    unique: [period: 60, fields: [:args], keys: [:block_hash]]

  require Logger
  alias Bitblocks.{Repo, Chain}
  alias Bitblocks.Chain.Block
  alias Bitblocks.Sync.DatabaseWriter

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"block_hash" => block_hash}}) do
    Logger.info("Fetching transactions for block #{block_hash}")

    with {:ok, block} <- get_block(block_hash),
         {:ok, block} <- transition_to_syncing(block),
         {:ok, transactions} <- fetch_transactions(block),
         {:ok, _} <- DatabaseWriter.store_transactions(transactions),
         {:ok, _block} <- transition_to_completed(block) do
      Logger.info(
        "Successfully fetched #{length(transactions)} transactions for block #{block_hash}"
      )

      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to fetch transactions for block #{block_hash}: #{inspect(reason)}")

        # Try to mark block as failed
        with {:ok, block} <- get_block(block_hash) do
          transition_to_failed(block, reason)
        end

        error
    end
  end

  defp get_block(block_hash) do
    case Repo.get_by(Block, hash: block_hash) do
      nil -> {:error, :block_not_found}
      block -> {:ok, block}
    end
  end

  defp transition_to_syncing(block) do
    # Just update the state directly without Machinery validation
    # since we're managing the workflow manually
    changeset =
      block
      |> Ecto.Changeset.change(%{
        sync_state: "txs_syncing",
        tx_sync_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    case Repo.update(changeset) do
      {:ok, updated_block} -> {:ok, updated_block}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_transactions(%Block{tx: tx_ids}) when is_list(tx_ids) do
    transactions =
      Enum.map(tx_ids, fn txid ->
        case BitcoinsvCli.getrawtransaction(txid, 1) do
          tx when is_map(tx) ->
            {:ok,
             %{
               txid: tx["txid"],
               raw: tx["hex"],
               block_hash: tx["blockhash"],
               version: to_string(tx["version"] || 1),
               inputs: (tx["vin"] || []) |> Enum.map(&Jason.encode!/1),
               outputs: (tx["vout"] || []) |> Enum.map(&Jason.encode!/1)
             }}

          error ->
            Logger.warning("Failed to fetch transaction #{txid}: #{inspect(error)}")
            {:error, txid}
        end
      end)

    # Separate successful and failed transactions
    {successful, failed} =
      Enum.split_with(transactions, fn
        {:ok, _} -> true
        _ -> false
      end)

    if length(failed) > 0 do
      Logger.warning("#{length(failed)} transactions failed to fetch")
    end

    successful_txs = Enum.map(successful, fn {:ok, tx} -> tx end)
    {:ok, successful_txs}
  end

  defp transition_to_completed(block) do
    changeset =
      block
      |> Ecto.Changeset.change(%{
        sync_state: "completed",
        tx_sync_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    case Repo.update(changeset) do
      {:ok, updated_block} -> {:ok, updated_block}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition_to_failed(block, error) do
    changeset =
      block
      |> Ecto.Changeset.change(%{
        sync_state: "failed",
        tx_sync_error: inspect(error),
        tx_sync_attempts: (block.tx_sync_attempts || 0) + 1
      })

    case Repo.update(changeset) do
      {:ok, updated_block} ->
        {:ok, updated_block}

      {:error, reason} ->
        Logger.error("Failed to transition block to failed state: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
