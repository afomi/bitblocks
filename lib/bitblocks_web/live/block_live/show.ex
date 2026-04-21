defmodule BitblocksWeb.BlockLive.Show do
  use BitblocksWeb, :live_view

  import Bitwise

  alias Bitblocks.Chain

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :downloading, false)}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    case Chain.get_block(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Block not found: #{id}")
         |> push_navigate(to: ~p"/blocks")}

      block ->
        transactions_downloaded = Chain.block_transactions_downloaded?(block)

        {:noreply,
         socket
         |> assign(:page_title, page_title(socket.assigns.live_action))
         |> assign(:block, block)
         |> assign(:transactions_downloaded, transactions_downloaded)}
    end
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

  defp page_title(:show), do: "Show Block"
  defp page_title(:edit), do: "Edit Block"

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp format_number(number), do: to_string(number)

  # Decode compact bits into leading zero hex characters required in a valid hash.
  # Bits format: first byte = exponent (byte length of target), next 3 bytes = mantissa.
  # Each leading zero byte = 2 zero hex chars. We also count leading zero nibbles in the mantissa.
  defp bits_to_leading_zero_chars(nil), do: nil

  defp bits_to_leading_zero_chars(bits) when is_binary(bits) do
    case Integer.parse(bits, 16) do
      {compact, ""} ->
        exponent = compact >>> 24
        mantissa = compact &&& 0x00FFFFFF
        zero_bytes = 32 - exponent
        mantissa_zero_nibbles = count_leading_zero_nibbles(mantissa, 6)
        zero_bytes * 2 + mantissa_zero_nibbles

      _ ->
        nil
    end
  end

  defp count_leading_zero_nibbles(0, _), do: 0
  defp count_leading_zero_nibbles(value, nibbles_remaining) when nibbles_remaining > 0 do
    if (value >>> ((nibbles_remaining - 1) * 4) &&& 0xF) == 0 do
      1 + count_leading_zero_nibbles(value, nibbles_remaining - 1)
    else
      0
    end
  end
  defp count_leading_zero_nibbles(_, 0), do: 0
end
