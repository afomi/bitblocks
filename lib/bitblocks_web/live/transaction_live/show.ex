defmodule BitblocksWeb.TransactionLive.Show do
  use BitblocksWeb, :live_view

  alias Bitblocks.{Chain, TransactionParser, Collections, TxStore}
  alias Bitblocks.Bitcom.BFile
  alias Bitblocks.Script.{Descriptor, Templates}
  alias BitblocksWeb.TxSummary

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       collection_item: nil,
       collection_holding: nil,
       collection_slug: nil,
       collection_module: nil,
       input_satoshis: %{},
       output_descriptors: [],
       script_templates: %{},
       output_protocols: %{},
       output_status: nil,
       nft_facts: nil,
       tx_state: :not_downloaded,
       protocol_links: [],
       b_file: nil,
       descriptors_by_vout: %{}
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    transaction = Chain.get_transaction(id)

    if is_nil(transaction) do
      {:noreply,
       socket
       |> put_flash(:error, "Transaction not found: #{id}")
       |> push_navigate(to: ~p"/blocks")}
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

    # A row whose bytes live only in the tx store reads them from there.
    transaction = TxStore.with_raw(transaction)

    # Get the block for this transaction
    block =
      if transaction do
        Chain.get_block(transaction.block_hash) ||
          (transaction.block_height && Chain.get_block_at_height(transaction.block_height))
      end

    # Decode `raw` exactly once; everything downstream (OP_RETURN parsing,
    # coinbase message, input satoshis, output descriptors) reuses this tx.
    decoded_tx =
      if transaction && transaction.raw do
        case Bitblocks.Chain.SafeTx.from_hex(transaction.raw) do
          {:ok, tx} -> tx
          {:error, _reason} -> nil
        end
      else
        nil
      end

    # Parse the decoded transaction for OP_RETURN data
    parsed_data =
      if decoded_tx do
        parsed = TransactionParser.parse_transaction(decoded_tx)

        # Use cached total_output_satoshis if available, otherwise fall back to parsed value
        total_output_satoshis =
          transaction.total_output_satoshis || parsed.total_output_satoshis

        %{parsed | total_output_satoshis: total_output_satoshis}
      else
        nil
      end

    # One descriptor per output: type, semantic fields, ASM, both hashes.
    output_descriptors =
      if decoded_tx, do: Descriptor.from_tx(decoded_tx), else: []

    # Batch the registered-template lookups once per page load (unknown
    # scripts only) — the script_card component never queries per-render.
    script_templates = lookup_script_templates(output_descriptors)

    # vout => detected protocol handler names, for OP_RETURN outputs only.
    output_protocols = detect_output_protocols(decoded_tx)

    # Coinbase scriptSig text (miner message, e.g. genesis "...Chancellor..."),
    # extracted from the already-decoded tx. nil for non-coinbase / no text.
    coinbase_message =
      case decoded_tx && TransactionParser.coinbase_message(decoded_tx) do
        {:ok, msg} -> msg
        _ -> nil
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

    input_satoshis = build_input_satoshis(decoded_tx)
    nft_facts = transaction.txid && Chain.nft_facts(transaction.txid)

    protocol_links =
      TxSummary.protocol_links(
        transaction,
        decoded_tx,
        parsed_data && parsed_data.protocols,
        nft_facts
      )

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:transaction, transaction)
     |> assign(:block, block)
     |> assign(:parsed_data, parsed_data)
     |> assign(:decoded_tx, decoded_tx)
     |> assign(:coinbase_message, coinbase_message)
     |> assign(:collection_item, collection_item)
     |> assign(:collection_holding, collection_holding(collection_module, collection_item))
     |> assign(:collection_slug, collection_slug)
     |> assign(:collection_module, collection_module)
     |> assign(:input_satoshis, input_satoshis)
     |> assign(:output_descriptors, output_descriptors)
     |> assign(:script_templates, script_templates)
     |> assign(:output_protocols, output_protocols)
     |> assign(:output_status, transaction.txid && Chain.output_status(transaction.txid))
     |> assign(:nft_facts, nft_facts)
     |> assign(:tx_state, TxSummary.state(transaction, decoded_tx))
     |> assign(:protocol_links, protocol_links)
     |> assign(:b_file, b_file(decoded_tx))
     |> assign(:descriptors_by_vout, Map.new(output_descriptors, &{&1.vout, &1}))
     |> assign(:stas_outputs, stas_outputs(decoded_tx))
     |> assign_locks(decoded_tx, transaction.txid)}
  end

  # HodLocker (#75): what this tx's time locks back; nLockTime (#76): the
  # tx's own lock. Our tip says how far each lock has left, read only when
  # the tx carries one.
  defp assign_locks(socket, decoded_tx, txid) do
    hodlocker = decoded_tx && txid && Bitblocks.HodLocker.parse(decoded_tx, txid)
    nlocktime = decoded_tx && Bitblocks.NLockTime.parse(decoded_tx)
    tip = if hodlocker || nlocktime, do: Bitblocks.ChainTiles.chain_tip()

    socket
    |> assign(:hodlocker, hodlocker || nil)
    |> assign(:nlocktime, nlocktime || nil)
    |> assign(:tip_height, tip)
    |> assign(:tip_time, tip_time(nlocktime, tip))
  end

  # A time lock is compared with the tip block's time.
  defp tip_time(%{kind: :time}, tip) when is_integer(tip) do
    case Chain.get_block_at_height(tip) do
      %{time: time} when is_integer(time) -> DateTime.from_unix!(time)
      _ -> nil
    end
  end

  defp tip_time(_nlocktime, _tip), do: nil

  @doc """
  How a lock stands at our tip: `{:locked, blocks_left}`, `:unlocked`, or
  `:unknown` with no tip.
  """
  def lock_state(_unlock_height, nil), do: :unknown
  def lock_state(unlock_height, tip) when tip >= unlock_height, do: :unlocked
  def lock_state(unlock_height, tip), do: {:locked, unlock_height - tip}

  @doc """
  The STAS token outputs of a decoded tx (#78), as `{vout, satoshis, token}`
  with the token from `Bitblocks.Stas.parse/1`.
  """
  def stas_outputs(%BSV.Tx{outputs: outputs}) do
    for {%BSV.TxOut{script: script, satoshis: sats}, vout} <- Enum.with_index(outputs),
        Bitblocks.Stas.stas?(script),
        {:ok, token} = Bitblocks.Stas.parse(script),
        do: {vout, sats, token}
  end

  def stas_outputs(_decoded_tx), do: []

  @doc """
  The tx's B:// file as the summary names it: filename, media type, size,
  and its C:// address (the sha256 of its bytes). nil when there is none.
  """
  def b_file(%BSV.Tx{} = tx) do
    case BFile.parse(tx) do
      {:ok, file} ->
        %{
          filename: file.filename,
          media_type: file.media_type,
          size: byte_size(file.content),
          sha256: :crypto.hash(:sha256, file.content) |> Base.encode16(case: :lower)
        }

      :error ->
        nil
    end
  end

  def b_file(_decoded_tx), do: nil

  # Outputs listed in the value card; the rest are counted.
  @status_rows 100

  @doc false
  def status_rows, do: @status_rows

  # The most raw hex the page shows: 1,000 bytes. Part of a tx is no use to
  # anyone, so a larger one is a download instead.
  @raw_shown_chars 2_000

  @doc """
  A tx's raw hex for the page, whole or not at all, and its size in bytes.
  """
  def raw_shown(nil), do: {nil, 0}

  def raw_shown(raw) do
    {if(byte_size(raw) <= @raw_shown_chars, do: raw), div(byte_size(raw), 2)}
  end

  # Map of template_hash => registered %Bitblocks.Script.Template{} for the
  # unknown-script outputs of this transaction. Hashes without a registered
  # template are omitted.
  defp detect_output_protocols(nil), do: %{}

  defp detect_output_protocols(decoded_tx) do
    decoded_tx.outputs
    |> TransactionParser.extract_op_returns()
    |> Map.new(fn %{output_index: vout, data: data} ->
      {vout, Bitblocks.Protocol.Handlers.detect_all(data)}
    end)
  end

  defp lookup_script_templates(output_descriptors) do
    output_descriptors
    |> Enum.filter(&(&1.type == :unknown))
    |> Enum.map(& &1.template_hash)
    |> Enum.uniq()
    |> Enum.flat_map(fn hash ->
      case Templates.get_by_hash(hash) do
        nil -> []
        template -> [{hash, template}]
      end
    end)
    |> Map.new()
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

  defp format_satoshis(satoshis) do
    BitblocksWeb.ScriptComponents.format_satoshis(satoshis)
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

  # BCat protocol: prefix 15DHFxWZJT58f9nhyGnsRBqrgwK4W6h4Up
  # Discriminator: second push data == "c" → chunk tx; anything else → head tx
  # Head push layout: [prefix, info, mime, encoding, filename, flag, txid_1..txid_n, "|", ...]
  # Chunk txids are 32 raw bytes each (push indices 6+), hex-encoded for display

  def bcat_info(nil), do: nil

  def bcat_info(parsed_data) do
    if "BCat" in (parsed_data.protocols || []) do
      op_return = List.first(parsed_data.op_returns)
      if op_return, do: classify_bcat(op_return.data), else: nil
    end
  end

  defp classify_bcat(data) do
    push_data =
      Enum.filter(data, &(&1.type == :push_data))

    case push_data do
      [_prefix, %{utf8: "c"} | _rest] ->
        {:chunk}

      [_prefix, info, mime, encoding, filename, flag | txid_pushes] ->
        chunk_txids =
          txid_pushes
          |> Enum.take_while(&(&1.utf8 != "|"))
          |> Enum.filter(fn chunk -> chunk.length == 32 end)
          |> Enum.map(& &1.hex)

        {:head,
         %{
           info: blank_to_nil(info.utf8),
           mime_type: blank_to_nil(mime.utf8),
           encoding: blank_to_nil(encoding.utf8),
           filename: blank_to_nil(filename.utf8),
           flag: blank_to_nil(flag.utf8),
           chunk_txids: chunk_txids
         }}

      _ ->
        nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(" "), do: nil
  defp blank_to_nil(v), do: v

  # Build a map of {txid, vout} => satoshis by fetching source transactions for each input.
  # Returns an empty map if decoded_tx is nil or all inputs are coinbase.
  defp build_input_satoshis(nil), do: %{}

  defp build_input_satoshis(%BSV.Tx{inputs: inputs}) do
    coinbase_txid = String.duplicate("0", 64)

    outpoints =
      inputs
      |> Enum.map(fn input ->
        txid = BSV.OutPoint.get_txid(input.outpoint)
        {txid, input.outpoint.vout}
      end)
      |> Enum.reject(fn {txid, _vout} -> txid == coinbase_txid end)

    txids = outpoints |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    source_txs =
      txids
      |> Enum.flat_map(fn txid ->
        case Chain.get_transaction(txid) do
          nil -> []
          tx -> [{txid, TxStore.with_raw(tx)}]
        end
      end)
      |> Map.new()

    Enum.reduce(outpoints, %{}, fn {txid, vout}, acc ->
      with %{raw: raw} when is_binary(raw) <- Map.get(source_txs, txid),
           {:ok, decoded} <- Bitblocks.Chain.SafeTx.from_hex(raw),
           output when not is_nil(output) <- Enum.at(decoded.outputs, vout) do
        Map.put(acc, {txid, vout}, output.satoshis)
      else
        _ -> acc
      end
    end)
  end

  defp page_title(:show), do: "Show Transaction"
  defp page_title(:edit), do: "Edit Transaction"

  defp collection_holding(Bitblocks.Rexxies, item), do: Bitblocks.Rexxies.holding(item)
  defp collection_holding(_module, _item), do: nil
end
