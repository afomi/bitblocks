defmodule BitblocksWeb.BlockLive.Show do
  use BitblocksWeb, :live_view

  import Bitwise

  alias Bitblocks.Chain

  @tx_page_size 50

  # Assigns hold the block WITHOUT its txid array (`block.tx` is nil) plus
  # one page of txids (`:txids`) and the array length (`:tx_total`). Large
  # blocks list millions of txids; a socket must never carry them all.
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, tx_page: 1, txids: [], tx_total: 0)}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    # Unsubscribe from previous block if navigating between blocks
    if old = socket.assigns[:block] do
      Phoenix.PubSub.unsubscribe(Bitblocks.PubSub, "block:#{old.hash}")
    end

    # A missing block raises Ecto.NoResultsError, which renders a 404.
    {block, tx_total} = Chain.get_block_for_display!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Bitblocks.PubSub, "block:#{block.hash}")
    end

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign_block(block, tx_total)
     |> assign_tx_page(1)}
  end

  @impl true
  def handle_event("tx_page", %{"page" => page}, socket) do
    page =
      case Integer.parse(to_string(page)) do
        {page, ""} -> page |> max(1) |> min(total_pages(socket.assigns.tx_total))
        _ -> 1
      end

    {:noreply, assign_tx_page(socket, page)}
  end

  @impl true
  def handle_info({:block_updated, updated_block}, socket) do
    # The broadcast carries the full row; reload without the txid array.
    {block, tx_total} = Chain.get_block_for_display!(updated_block.hash)

    {:noreply,
     socket
     |> assign_block(block, tx_total)
     |> assign_tx_page(socket.assigns.tx_page)}
  end

  defp assign_block(socket, block, tx_total) do
    # No txid list on the row (raw-block path, big blocks): page the stored
    # transactions instead (Chain.BlockTxids), and count those.
    tx_total = if tx_total > 0, do: tx_total, else: Bitblocks.Chain.BlockTxids.count(block)

    socket
    |> assign(:block, block)
    |> assign(:tx_total, tx_total)
  end

  defp assign_tx_page(socket, page) do
    txids = Bitblocks.Chain.BlockTxids.page(socket.assigns.block, page, @tx_page_size)

    socket
    |> assign(:tx_page, page)
    |> assign(:txids, txids)
    |> assign(:tx_summaries, Bitblocks.Chain.BlockTxids.summaries(socket.assigns.block, txids))
  end

  defp total_pages(0), do: 1
  defp total_pages(total), do: ceil(total / @tx_page_size)

  def tx_page_size, do: @tx_page_size

  @doc false
  def tx_total_pages(total), do: total_pages(total)

  defp page_title(:show), do: "Show Block"

  # What `completed` means (docs/SYNCING.md), said for this block.
  @doc false
  def complete_sentence(1), do: "Its one transaction is stored, and its txid is the merkle root."

  def complete_sentence(n) when is_integer(n) and n > 1,
    do:
      "All #{format_number(n)} transactions are stored, and their txids rebuild the merkle root."

  def complete_sentence(_),
    do: "Every transaction is stored, and their txids rebuild the merkle root."

  # A stored tx's types as short labels, `custom` last and only when alone
  # with nothing else, so the row reads what the tx does.
  @doc false
  def type_labels(%{tx_types: types}) when is_list(types) do
    named = Enum.reject(types, &(&1 == "custom"))
    ids = if named == [], do: types, else: named

    for id <- ids, type = Bitblocks.TxTypes.get(id), do: {id, type.short}
  end

  def type_labels(_), do: []

  # The sync stages a block passes through, in words.
  @doc false
  def step_label("header_only"), do: "Header"
  def step_label("header_synced"), do: "Txid list"
  def step_label("txs_queued"), do: "Queued"
  def step_label("txs_syncing"), do: "Fetching txs"
  def step_label("completed"), do: "Complete"
  def step_label(step), do: String.replace(step, "_", " ")

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
