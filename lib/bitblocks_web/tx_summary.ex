defmodule BitblocksWeb.TxSummary do
  @moduledoc """
  What a transaction did, in the words the top of its page uses: the state of
  its bytes, one sentence on what moved, and the protocols it belongs to, each
  linked to that protocol's page. Pure: everything comes from the row and the
  tx the page has already decoded, so it costs no query.
  """

  alias Bitblocks.Bsv20Parser
  alias Bitblocks.Protocol.{Context, Handlers}
  alias BitblocksWeb.Sats

  @type state :: :decoded | :not_downloaded | :undecodable
  @type link :: %{label: String.t(), path: String.t()}

  # Protocols with a page of their own. The rest of the prefix protocols link
  # to their Bitcom namespace, and anything else to the registry.
  @pages %{
    "B://" => "/types/b",
    "MAP" => "/types/map",
    "AIP" => "/types/aip",
    "Run" => "/types/run",
    "1SAT Ordinals" => "/types/1sat-inscription",
    "OrderBook" => "/order-book"
  }

  @labels %{"OrderBook" => "Order book", "1SAT Ordinals" => "1Sat inscription"}

  @doc """
  Where a row's bytes stand: `:not_downloaded` when it holds no raw hex,
  `:undecodable` when it holds hex that won't decode, else `:decoded`.
  """
  @spec state(%{raw: String.t() | nil}, BSV.Tx.t() | nil) :: state()
  def state(%{raw: raw}, _decoded) when raw in [nil, ""], do: :not_downloaded
  def state(_transaction, %BSV.Tx{}), do: :decoded
  def state(_transaction, _decoded), do: :undecodable

  @doc "True for a coinbase: one input, spending nothing."
  @spec coinbase?(BSV.Tx.t() | nil) :: boolean()
  def coinbase?(%BSV.Tx{inputs: [%BSV.TxIn{script: %BSV.Script{coinbase: coinbase}}]})
      when not is_nil(coinbase),
      do: true

  def coinbase?(_tx), do: false

  @doc "One sentence on what a decoded tx moved, given its total output in sats."
  @spec headline(BSV.Tx.t(), integer() | nil, map() | nil) :: String.t()
  def headline(%BSV.Tx{} = tx, total, block) do
    if coinbase?(tx) do
      who = if block, do: "Block #{Sats.delimit(block.height)}", else: "This block"
      "Coinbase: #{who} paid its miner #{Sats.bsv(total)}."
    else
      "Spends #{count(length(tx.inputs), "input")} to create " <>
        "#{count(length(tx.outputs), "output")}, paying #{Sats.bsv(total)} in total."
    end
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{Sats.delimit(n)} #{noun}s"

  @doc """
  The protocols a tx belongs to, as links: its `protocols` tags, then any
  collection it is part of (`nft_facts`). A tx may name several; each page
  appears once.
  """
  @spec protocol_links(map(), BSV.Tx.t() | nil, [String.t()], map() | nil) :: [link()]
  def protocol_links(transaction, decoded, parsed_protocols, nft_facts) do
    tags = Enum.uniq((transaction.protocols || []) ++ (parsed_protocols || []))

    collections =
      for %{slug: slug, name: name} <- (nft_facts && nft_facts.collections) || [],
          do: %{label: name, path: "/collections/#{slug}"}

    (Enum.map(tags, &link(&1, transaction, decoded)) ++ collections)
    |> Enum.uniq_by(& &1.path)
  end

  defp link("BSV20", transaction, decoded) do
    case first_token(decoded) do
      {token, vout} ->
        %{label: token_label(token), path: token_path(token, transaction.txid, vout)}

      nil ->
        %{label: "Token", path: "/tokens"}
    end
  end

  defp link("Bitcom", _transaction, decoded) do
    case Context.first_input_address(decoded) do
      nil -> %{label: "Bitcom", path: "/bitcom"}
      address -> %{label: "Bitcom", path: "/bitcom/#{address}"}
    end
  end

  defp link("Metanet", transaction, _decoded),
    do: %{label: "Metanet", path: "/metanet?" <> URI.encode_query(txid: transaction.txid)}

  defp link(name, _transaction, _decoded) do
    %{label: Map.get(@labels, name, name), path: Map.get_lazy(@pages, name, fn -> page(name) end)}
  end

  defp page(name) do
    case Handlers.get(name) do
      nil ->
        "/protocols"

      handler ->
        case handler.segment_matcher() do
          {:prefix, address} -> "/bitcom/#{address}"
          _ -> "/protocols"
        end
    end
  end

  defp first_token(%BSV.Tx{outputs: outputs}) do
    outputs
    |> Enum.with_index()
    |> Enum.find_value(fn {output, vout} ->
      case Bsv20Parser.parse(output.script) do
        {:ok, token} -> {token, vout}
        _ -> nil
      end
    end)
  end

  defp first_token(_decoded), do: nil

  defp token_label(%{standard: "bsv-21"}), do: "BSV-21 token"
  defp token_label(_token), do: "BSV-20 token"

  # A mint is its own token id; a transfer names one, or a ticker.
  defp token_path(%{op: "deploy+mint"}, txid, vout), do: "/tokens/#{txid}_#{vout}"
  defp token_path(%{token_id: id}, _txid, _vout) when is_binary(id), do: "/tokens/#{id}"

  defp token_path(%{tick: tick}, _txid, _vout) when is_binary(tick),
    do: "/tokens/#{URI.encode(tick, &URI.char_unreserved?/1)}"

  defp token_path(_token, _txid, _vout), do: "/tokens"

  @doc """
  Who an output pays, for a person: an address where the script has one, else
  the kind of script.
  """
  @spec paid_to(Bitblocks.Script.Descriptor.t() | nil) :: String.t()
  def paid_to(nil), do: "—"

  def paid_to(%{type: :p2pkh, fields: %{pubkey_hash: hash}}) do
    %BSV.Address{pubkey_hash: Base.decode16!(hash, case: :lower)} |> BSV.Address.to_string()
  end

  def paid_to(%{type: :p2pk, fields: %{pubkey: pubkey}}) do
    pubkey
    |> Base.decode16!(case: :lower)
    |> BSV.Address.from_pubkey()
    |> BSV.Address.to_string()
  rescue
    _ -> "Public key"
  end

  def paid_to(%{type: :p2sh}), do: "Script hash"
  def paid_to(%{type: :multisig, fields: %{m: m, n: n}}), do: "#{m}-of-#{n} multisig"
  def paid_to(%{type: :op_return}), do: "Data"
  def paid_to(_descriptor), do: "Script"
end
