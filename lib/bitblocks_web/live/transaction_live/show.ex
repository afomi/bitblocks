defmodule BitblocksWeb.TransactionLive.Show do
  use BitblocksWeb, :live_view

  alias Bitblocks.{Chain, TransactionParser}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    transaction = Chain.get_transaction!(id)

    # If transaction exists but hasn't been fully synced (no txid), fetch it on-demand
    transaction =
      if transaction && is_nil(transaction.txid) do
        case fetch_transaction_on_demand(id) do
          {:ok, tx} -> tx
          {:error, _} -> transaction
        end
      else
        transaction
      end

    # Get the block for this transaction
    block =
      cond do
        transaction && not is_nil(transaction.block_hash) ->
          Chain.get_block(transaction.block_hash) ||
            if transaction.block_height, do: Chain.get_block(transaction.block_height), else: nil

        transaction && transaction.block_height ->
          Chain.get_block(transaction.block_height)

        true ->
          nil
      end

    # Parse the transaction for OP_RETURN data
    parsed_data =
      if transaction && transaction.raw do
        case TransactionParser.parse_transaction(transaction.raw) do
          parsed when is_map(parsed) ->
            # Use cached total_output_satoshis if available, otherwise fall back to parsed value
            total_output_satoshis =
              transaction.total_output_satoshis || parsed.total_output_satoshis

            %{parsed | total_output_satoshis: total_output_satoshis}

          {:error, _reason} ->
            nil
        end
      else
        nil
      end

    decoded_tx =
      if transaction && transaction.raw do
        case BSV.Tx.from_binary(transaction.raw, encoding: :hex) do
          {:ok, tx} -> tx
          {:error, _reason} -> nil
        end
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:transaction, transaction)
     |> assign(:block, block)
     |> assign(:parsed_data, parsed_data)
     |> assign(:decoded_tx, decoded_tx)}
  end

  defp fetch_transaction_on_demand(txid) do
    require Logger
    Logger.info("Fetching transaction on-demand: #{txid}")

    case BitcoinsvCli.getrawtransaction(txid, 1) do
      tx when is_map(tx) ->
        # Store the transaction
        attrs = %{
          txid: tx["txid"],
          raw: tx["hex"],
          block_hash: tx["blockhash"]
        }

        case Chain.update_transaction(
               Bitblocks.Repo.get!(Bitblocks.Chain.Transaction, txid),
               attrs
             ) do
          {:ok, updated_tx} -> {:ok, updated_tx}
          error -> error
        end

      error ->
        Logger.error("Failed to fetch transaction #{txid}: #{inspect(error)}")
        {:error, :rpc_failed}
    end
  end

  defp format_satoshis(satoshis) when is_number(satoshis) do
    bsv = satoshis / 100_000_000

    cond do
      satoshis < 100_000_000 ->
        # Show in satoshis if less than 1 BSV
        "#{:erlang.float_to_binary(satoshis * 1.0, decimals: 0)} sats"

      true ->
        # Show in BSV with proper decimal formatting
        "#{:erlang.float_to_binary(bsv, decimals: 8)} BSV"
    end
  end

  defp format_satoshis(_), do: "0 sats"

  defp page_title(:show), do: "Show Transaction"
  defp page_title(:edit), do: "Edit Transaction"
end
