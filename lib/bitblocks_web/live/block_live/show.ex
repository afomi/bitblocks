defmodule BitblocksWeb.BlockLive.Show do
  use BitblocksWeb, :live_view

  import Bitwise

  alias Bitblocks.Chain

  @tx_page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, downloading: false, tx_page: 1)}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    # Unsubscribe from previous block if navigating between blocks
    if old = socket.assigns[:block] do
      Phoenix.PubSub.unsubscribe(Bitblocks.PubSub, "block:#{old.hash}")
    end

    case Chain.get_block(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Block not found: #{id}")
         |> push_navigate(to: ~p"/blocks")}

      block ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Bitblocks.PubSub, "block:#{block.hash}")
        end

        transactions_downloaded = Chain.block_transactions_downloaded?(block)

        {:noreply,
         socket
         |> assign(:page_title, page_title(socket.assigns.live_action))
         |> assign(:block, block)
         |> assign(:transactions_downloaded, transactions_downloaded)
         |> assign(:tx_page, 1)}
    end
  end

  @impl true
  def handle_event("tx_page", %{"page" => page}, socket) do
    {:noreply, assign(socket, :tx_page, String.to_integer(page))}
  end

  @impl true
  def handle_event("download_transactions", _params, socket) do
    block = socket.assigns.block

    # Queue the job
    case Chain.queue_transaction_fetch(block) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:downloading, true)
         |> put_flash(:info, "Transaction download job queued for block #{block.height}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to queue job: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:block_updated, updated_block}, socket) do
    transactions_downloaded = Chain.block_transactions_downloaded?(updated_block)

    {:noreply,
     socket
     |> assign(:block, updated_block)
     |> assign(:transactions_downloaded, transactions_downloaded)
     |> assign(:downloading, !transactions_downloaded)}
  end

  def tx_page_size, do: @tx_page_size

  defp page_title(:show), do: "Show Block"
  defp page_title(:edit), do: "Edit Block"

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp format_number(number), do: to_string(number)

  # Decode compact bits into leading zero hex characters visible in a valid block hash.
  # Expands the compact target to a full 64-char hex string and counts leading zeros.
  # Bits format: first byte = exponent (target byte length), next 3 bytes = mantissa.
  # Target = mantissa * 2^(8 * (exponent - 3)), left-padded to 32 bytes.
  defp bits_to_leading_zero_chars(nil), do: nil

  defp bits_to_leading_zero_chars(bits) when is_binary(bits) do
    case Integer.parse(bits, 16) do
      {compact, ""} ->
        exponent = compact >>> 24
        mantissa = compact &&& 0x00FFFFFF
        shift = 8 * (exponent - 3)
        target = mantissa <<< shift
        target
        |> Integer.to_string(16)
        |> String.pad_leading(64, "0")
        |> count_leading_zero_hex_chars(0)

      _ ->
        nil
    end
  end

  defp count_leading_zero_hex_chars("", acc), do: acc
  defp count_leading_zero_hex_chars(<<"0", rest::binary>>, acc),
    do: count_leading_zero_hex_chars(rest, acc + 1)
  defp count_leading_zero_hex_chars(_, acc), do: acc
end
