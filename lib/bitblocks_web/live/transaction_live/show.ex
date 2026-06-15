defmodule BitblocksWeb.TransactionLive.Show do
  use BitblocksWeb, :live_view

  alias Bitblocks.{Chain, TransactionParser, Collections}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, collection_item: nil, collection_slug: nil, collection_module: nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    transaction = Chain.get_transaction(id)

    if is_nil(transaction) do
      {:noreply,
       socket
       |> put_flash(:error, "Transaction not found: #{id}")
       |> push_navigate(to: ~p"/transactions")}
    else
      handle_transaction_params(transaction, id, socket)
    end
  end

  defp handle_transaction_params(transaction, id, socket) do
    # If transaction exists but hasn't been fully synced (no txid), fetch it on-demand
    transaction =
      if is_nil(transaction.txid) do
        case fetch_transaction_on_demand(id) do
          {:ok, tx} -> tx
          {:error, _} -> transaction
        end
      else
        transaction
      end

    # Get the block for this transaction
    block =
      if transaction do
        Chain.get_block(transaction.block_hash) ||
          Chain.get_block(transaction.block_height)
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
        case Bitblocks.Chain.SafeTx.from_hex(transaction.raw) do
          {:ok, tx} -> tx
          {:error, _reason} -> nil
        end
      else
        nil
      end

    # Check if this transaction belongs to any registered collection
    {collection_slug, collection_item, collection_module} =
      if transaction && transaction.txid do
        case Collections.lookup_txid(transaction.txid) do
          {slug, item} ->
            module = Collections.get(slug)
            {slug, item, module}

          nil ->
            {nil, nil, nil}
        end
      else
        {nil, nil, nil}
      end

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:transaction, transaction)
     |> assign(:block, block)
     |> assign(:parsed_data, parsed_data)
     |> assign(:decoded_tx, decoded_tx)
     |> assign(:collection_item, collection_item)
     |> assign(:collection_slug, collection_slug)
     |> assign(:collection_module, collection_module)}
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
    bsv_str = :erlang.float_to_binary(bsv, decimals: 8)
    sats_str = satoshis |> round() |> Integer.to_string() |> format_integer_commas()
    "#{bsv_str} BSV (#{sats_str} sats)"
  end

  defp format_satoshis(_), do: "0 sats"

  defp format_integer_commas(str) do
    str
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def output_type_label(:p2pkh), do: "P2PKH"
  def output_type_label(:p2pk), do: "P2PK"
  def output_type_label(:p2sh), do: "P2SH"
  def output_type_label(:op_return), do: "OP_RETURN"
  def output_type_label(:unknown), do: "Script"

  def script_type_summary(outputs) do
    outputs
    |> Enum.map(&Bitblocks.TransactionParser.determine_script_type(&1.script))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_type, count} -> -count end)
  end

  defp page_title(:show), do: "Show Transaction"
  defp page_title(:edit), do: "Edit Transaction"
end
