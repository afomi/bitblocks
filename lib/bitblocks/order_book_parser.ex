defmodule Bitblocks.OrderBookParser do
  @moduledoc """
  Parses Open Order Book protocol data from OP_RETURN scripts.

  An OrderBook OP_RETURN has the structure:

      OP_RETURN "orderbook" <op> <fields...>

  Supported operations:

  - `list`   — publish a token listing
  - `cancel` — cancel an existing listing
  - `fill`   — record a purchase (optional indexing aid)
  """

  @orderbook_flag "orderbook"

  @type listing :: %{
          op: String.t(),
          token_id: String.t(),
          quantity: String.t(),
          price_satoshis: String.t(),
          seller_address: String.t(),
          token_utxo: String.t(),
          expires_at: String.t() | nil,
          min_quantity: String.t() | nil
        }

  @type cancellation :: %{
          op: String.t(),
          listing_txid: String.t()
        }

  @type fill :: %{
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
         {:ok, op} <- extract_operation(data_chunks) do
      case op do
        "list" -> parse_listing(data_chunks)
        "cancel" -> parse_cancellation(data_chunks)
        "fill" -> parse_fill(data_chunks)
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

  defp extract_operation(chunks) do
    case Enum.at(chunks, 1) do
      %{utf8: op} when is_binary(op) and op != "" -> {:ok, op}
      _ -> {:error, :missing_operation}
    end
  end

  # list: "orderbook" "list" <token_id> <quantity> <price_satoshis> <seller_address> <token_utxo> [expires_at] [min_quantity]
  defp parse_listing(chunks) do
    with {:ok, token_id} <- extract_utf8_required(chunks, 2, :missing_token_id),
         {:ok, quantity} <- extract_utf8_required(chunks, 3, :missing_quantity),
         {:ok, price_satoshis} <- extract_utf8_required(chunks, 4, :missing_price),
         {:ok, seller_address} <- extract_utf8_required(chunks, 5, :missing_seller_address),
         {:ok, token_utxo} <- extract_utf8_required(chunks, 6, :missing_token_utxo) do
      {:ok,
       %{
         op: "list",
         token_id: token_id,
         quantity: quantity,
         price_satoshis: price_satoshis,
         seller_address: seller_address,
         token_utxo: token_utxo,
         expires_at: extract_utf8_optional(chunks, 7),
         min_quantity: extract_utf8_optional(chunks, 8)
       }}
    end
  end

  # cancel: "orderbook" "cancel" <listing_txid>
  defp parse_cancellation(chunks) do
    with {:ok, listing_txid} <- extract_utf8_required(chunks, 2, :missing_listing_txid) do
      {:ok,
       %{
         op: "cancel",
         listing_txid: listing_txid
       }}
    end
  end

  # fill: "orderbook" "fill" <listing_txid> <fill_quantity> <buyer_address>
  defp parse_fill(chunks) do
    with {:ok, listing_txid} <- extract_utf8_required(chunks, 2, :missing_listing_txid),
         {:ok, fill_quantity} <- extract_utf8_required(chunks, 3, :missing_fill_quantity),
         {:ok, buyer_address} <- extract_utf8_required(chunks, 4, :missing_buyer_address) do
      {:ok,
       %{
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
