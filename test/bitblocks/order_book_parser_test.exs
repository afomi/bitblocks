defmodule Bitblocks.OrderBookParserTest do
  use ExUnit.Case, async: true

  alias Bitblocks.OrderBookParser

  @test_token_id "abc123def456_0"
  @test_seller "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
  @test_token_utxo "abc123def456:0"

  describe "parse/1 — list operation" do
    test "parses a well-formed listing with all fields" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("100"),
        make_chunk("5000"),
        make_chunk(@test_seller),
        make_chunk(@test_token_utxo),
        make_chunk("2026-06-01T00:00:00Z"),
        make_chunk("10")
      ]

      assert {:ok, listing} = OrderBookParser.parse(chunks)
      assert listing.op == "list"
      assert listing.token_id == @test_token_id
      assert listing.quantity == "100"
      assert listing.price_satoshis == "5000"
      assert listing.seller_address == @test_seller
      assert listing.token_utxo == @test_token_utxo
      assert listing.expires_at == "2026-06-01T00:00:00Z"
      assert listing.min_quantity == "10"
    end

    test "handles missing optional fields" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("50"),
        make_chunk("1000"),
        make_chunk(@test_seller),
        make_chunk(@test_token_utxo)
      ]

      assert {:ok, listing} = OrderBookParser.parse(chunks)
      assert listing.op == "list"
      assert listing.token_id == @test_token_id
      assert listing.expires_at == nil
      assert listing.min_quantity == nil
    end

    test "returns error when token_id is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("list")
      ]

      assert {:error, :missing_token_id} = OrderBookParser.parse(chunks)
    end

    test "returns error when quantity is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("list"),
        make_chunk(@test_token_id)
      ]

      assert {:error, :missing_quantity} = OrderBookParser.parse(chunks)
    end

    test "returns error when price is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("100")
      ]

      assert {:error, :missing_price} = OrderBookParser.parse(chunks)
    end

    test "returns error when seller_address is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("100"),
        make_chunk("5000")
      ]

      assert {:error, :missing_seller_address} = OrderBookParser.parse(chunks)
    end

    test "returns error when token_utxo is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("100"),
        make_chunk("5000"),
        make_chunk(@test_seller)
      ]

      assert {:error, :missing_token_utxo} = OrderBookParser.parse(chunks)
    end
  end

  describe "parse/1 — cancel operation" do
    test "parses a well-formed cancellation" do
      listing_txid = String.duplicate("ab", 32)

      chunks = [
        make_chunk("orderbook"),
        make_chunk("cancel"),
        make_chunk(listing_txid)
      ]

      assert {:ok, cancel} = OrderBookParser.parse(chunks)
      assert cancel.op == "cancel"
      assert cancel.listing_txid == listing_txid
    end

    test "returns error when listing_txid is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("cancel")
      ]

      assert {:error, :missing_listing_txid} = OrderBookParser.parse(chunks)
    end
  end

  describe "parse/1 — fill operation" do
    test "parses a well-formed fill" do
      listing_txid = String.duplicate("cd", 32)
      buyer_address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

      chunks = [
        make_chunk("orderbook"),
        make_chunk("fill"),
        make_chunk(listing_txid),
        make_chunk("25"),
        make_chunk(buyer_address)
      ]

      assert {:ok, fill} = OrderBookParser.parse(chunks)
      assert fill.op == "fill"
      assert fill.listing_txid == listing_txid
      assert fill.fill_quantity == "25"
      assert fill.buyer_address == buyer_address
    end

    test "returns error when fill_quantity is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("fill"),
        make_chunk(String.duplicate("cd", 32))
      ]

      assert {:error, :missing_fill_quantity} = OrderBookParser.parse(chunks)
    end

    test "returns error when buyer_address is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("fill"),
        make_chunk(String.duplicate("cd", 32)),
        make_chunk("25")
      ]

      assert {:error, :missing_buyer_address} = OrderBookParser.parse(chunks)
    end
  end

  describe "parse/1 — error cases" do
    test "returns error for non-orderbook data" do
      chunks = [
        make_chunk("meta"),
        make_chunk("some data")
      ]

      assert {:error, :not_orderbook} = OrderBookParser.parse(chunks)
    end

    test "returns error for unknown operation" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("unknown_op")
      ]

      assert {:error, :unknown_operation} = OrderBookParser.parse(chunks)
    end

    test "returns error when operation is missing" do
      chunks = [make_chunk("orderbook")]

      assert {:error, :missing_operation} = OrderBookParser.parse(chunks)
    end

    test "returns error for non-list input" do
      assert {:error, :invalid_data} = OrderBookParser.parse("not a list")
    end
  end

  # Helper: make a push_data chunk from a UTF-8 string
  defp make_chunk(text) do
    %{
      type: :push_data,
      utf8: text,
      hex: Base.encode16(text, case: :lower),
      length: byte_size(text)
    }
  end
end
