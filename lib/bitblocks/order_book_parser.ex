defmodule Bitblocks.OrderBookParser do
  @moduledoc """
  Parses Open Order Book protocol data from OP_RETURN scripts.

  An OrderBook OP_RETURN has the structure:

      OP_RETURN "orderbook" <version> <op> <fields...>

  The version chunk (currently `"1"`) sits before the operation so it governs
  the whole protocol. Parsing branches on version first, then on operation, so a
  future `"2"` can change fields without breaking `"1"` messages already on-chain.
  A message with a missing or unknown version is rejected (never silently parsed
  as v1).

  Supported operations (v1):

  - `list`   — publish a token listing (carries the seller's pre-signed offer)
  - `cancel` — cancel an existing listing
  - `fill`   — record a purchase (optional indexing aid)
  """

  @orderbook_flag "orderbook"
  @supported_versions ~w(1)

  @type listing :: %{
          version: String.t(),
          op: String.t(),
          token_id: String.t(),
          quantity: String.t(),
          price_satoshis: String.t(),
          seller_address: String.t(),
          token_utxo: String.t(),
          seller_pubkey: String.t(),
          seller_sig: String.t(),
          sighash_flag: String.t(),
          expires_at: String.t() | nil,
          min_quantity: String.t() | nil
        }

  @type cancellation :: %{
          version: String.t(),
          op: String.t(),
          listing_txid: String.t()
        }

  @type fill :: %{
          version: String.t(),
          op: String.t(),
          listing_txid: String.t(),
          fill_quantity: String.t(),
          buyer_address: String.t()
        }

  @doc """
  Parses OrderBook data from a list of parsed OP_RETURN data chunks.

  Chunks are in the format returned by `TransactionParser.parse_op_return_data/1`:
  `[%{type: :push_data, hex: "...", utf8: "...", length: N}, ...]`

  Returns `{:ok, parsed_map}` or `{:error, reason}`.
  """
  @spec parse(list(map())) :: {:ok, map()} | {:error, atom()}
  def parse(data_chunks) when is_list(data_chunks) do
    with :ok <- validate_flag(data_chunks),
         {:ok, version} <- extract_version(data_chunks),
         {:ok, op} <- extract_operation(data_chunks) do
      case op do
        "list" -> parse_listing(data_chunks, version)
        "cancel" -> parse_cancellation(data_chunks, version)
        "fill" -> parse_fill(data_chunks, version)
        _ -> {:error, :unknown_operation}
      end
    end
  end

  def parse(_), do: {:error, :invalid_data}

  # -- Private ----------------------------------------------------------------

  defp validate_flag(chunks) do
    case Enum.at(chunks, 0) do
      %{utf8: @orderbook_flag} -> :ok
      _ -> {:error, :not_orderbook}
    end
  end

  # Version is the second chunk (index 1). Reject anything we don't know how to
  # parse rather than guessing — the version is a hard gate, not a soft default.
  defp extract_version(chunks) do
    case Enum.at(chunks, 1) do
      %{utf8: version} when version in @supported_versions -> {:ok, version}
      %{utf8: v} when is_binary(v) and v != "" -> {:error, :unsupported_version}
      _ -> {:error, :missing_version}
    end
  end

  # Operation is the third chunk (index 2), after flag and version.
  defp extract_operation(chunks) do
    case Enum.at(chunks, 2) do
      %{utf8: op} when is_binary(op) and op != "" -> {:ok, op}
      _ -> {:error, :missing_operation}
    end
  end

  # list (v1): "orderbook" "1" "list" <token_id> <quantity> <price_satoshis>
  #   <seller_address> <token_utxo> <seller_pubkey> <seller_sig> <sighash_flag>
  #   [expires_at] [min_quantity]
  defp parse_listing(chunks, version) do
    with {:ok, token_id} <- extract_utf8_required(chunks, 3, :missing_token_id),
         {:ok, quantity} <- extract_utf8_required(chunks, 4, :missing_quantity),
         {:ok, price_satoshis} <- extract_utf8_required(chunks, 5, :missing_price),
         {:ok, seller_address} <- extract_utf8_required(chunks, 6, :missing_seller_address),
         {:ok, token_utxo} <- extract_utf8_required(chunks, 7, :missing_token_utxo),
         {:ok, seller_pubkey} <- extract_utf8_required(chunks, 8, :missing_seller_pubkey),
         {:ok, seller_sig} <- extract_utf8_required(chunks, 9, :missing_seller_sig),
         {:ok, sighash_flag} <- extract_utf8_required(chunks, 10, :missing_sighash_flag) do
      {:ok,
       %{
         version: version,
         op: "list",
         token_id: token_id,
         quantity: quantity,
         price_satoshis: price_satoshis,
         seller_address: seller_address,
         token_utxo: token_utxo,
         seller_pubkey: seller_pubkey,
         seller_sig: seller_sig,
         sighash_flag: sighash_flag,
         expires_at: extract_utf8_optional(chunks, 11),
         min_quantity: extract_utf8_optional(chunks, 12)
       }}
    end
  end

  # cancel (v1): "orderbook" "1" "cancel" <listing_txid>
  defp parse_cancellation(chunks, version) do
    with {:ok, listing_txid} <- extract_utf8_required(chunks, 3, :missing_listing_txid) do
      {:ok,
       %{
         version: version,
         op: "cancel",
         listing_txid: listing_txid
       }}
    end
  end

  # fill (v1): "orderbook" "1" "fill" <listing_txid> <fill_quantity> <buyer_address>
  defp parse_fill(chunks, version) do
    with {:ok, listing_txid} <- extract_utf8_required(chunks, 3, :missing_listing_txid),
         {:ok, fill_quantity} <- extract_utf8_required(chunks, 4, :missing_fill_quantity),
         {:ok, buyer_address} <- extract_utf8_required(chunks, 5, :missing_buyer_address) do
      {:ok,
       %{
         version: version,
         op: "fill",
         listing_txid: listing_txid,
         fill_quantity: fill_quantity,
         buyer_address: buyer_address
       }}
    end
  end

  defp extract_utf8_required(chunks, index, error_key) do
    case Enum.at(chunks, index) do
      %{utf8: value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error_key}
    end
  end

  defp extract_utf8_optional(chunks, index) do
    case Enum.at(chunks, index) do
      %{utf8: value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
