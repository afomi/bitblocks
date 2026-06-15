defmodule Bitblocks.OrderBookParserTest do
  use ExUnit.Case, async: true

  alias Bitblocks.OrderBookParser

  @test_token_id "abc123def456_0"
  @test_seller "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
  @test_token_utxo "abc123def456:0"
  @test_pubkey "02a1633cafcc01ebfb6d78e39f687a1f0995c62fc95f51ead10a02ee0be551b5dc"
  @test_sig "3045022100abcdef" <> "c1"
  @test_sighash "0xc1"

  describe "parse/1 — list operation (v1)" do
    test "parses a well-formed listing with all fields" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("100"),
        make_chunk("5000"),
        make_chunk(@test_seller),
        make_chunk(@test_token_utxo),
        make_chunk(@test_pubkey),
        make_chunk(@test_sig),
        make_chunk(@test_sighash),
        make_chunk("2026-06-01T00:00:00Z"),
        make_chunk("100")
      ]

      assert {:ok, listing} = OrderBookParser.parse(chunks)
      assert listing.version == "1"
      assert listing.op == "list"
      assert listing.token_id == @test_token_id
      assert listing.quantity == "100"
      assert listing.price_satoshis == "5000"
      assert listing.seller_address == @test_seller
      assert listing.token_utxo == @test_token_utxo
      assert listing.seller_pubkey == @test_pubkey
      assert listing.seller_sig == @test_sig
      assert listing.sighash_flag == @test_sighash
      assert listing.expires_at == "2026-06-01T00:00:00Z"
      assert listing.min_quantity == "100"
    end

    test "handles missing optional fields" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("50"),
        make_chunk("1000"),
        make_chunk(@test_seller),
        make_chunk(@test_token_utxo),
        make_chunk(@test_pubkey),
        make_chunk(@test_sig),
        make_chunk(@test_sighash)
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
        make_chunk("1"),
        make_chunk("list")
      ]

      assert {:error, :missing_token_id} = OrderBookParser.parse(chunks)
    end

    test "returns error when the pre-signed offer fields are missing" do
      # All required listing fields present except the offer (pubkey/sig/sighash)
      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("100"),
        make_chunk("5000"),
        make_chunk(@test_seller),
        make_chunk(@test_token_utxo)
      ]

      assert {:error, :missing_seller_pubkey} = OrderBookParser.parse(chunks)
    end

    test "returns error when seller_sig is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("100"),
        make_chunk("5000"),
        make_chunk(@test_seller),
        make_chunk(@test_token_utxo),
        make_chunk(@test_pubkey)
      ]

      assert {:error, :missing_seller_sig} = OrderBookParser.parse(chunks)
    end

    test "returns error when token_utxo is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("list"),
        make_chunk(@test_token_id),
        make_chunk("100"),
        make_chunk("5000"),
        make_chunk(@test_seller)
      ]

      assert {:error, :missing_token_utxo} = OrderBookParser.parse(chunks)
    end
  end

  describe "parse/1 — cancel operation (v1)" do
    test "parses a well-formed cancellation" do
      listing_txid = String.duplicate("ab", 32)

      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("cancel"),
        make_chunk(listing_txid)
      ]

      assert {:ok, cancel} = OrderBookParser.parse(chunks)
      assert cancel.version == "1"
      assert cancel.op == "cancel"
      assert cancel.listing_txid == listing_txid
    end

    test "returns error when listing_txid is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("cancel")
      ]

      assert {:error, :missing_listing_txid} = OrderBookParser.parse(chunks)
    end
  end

  describe "parse/1 — fill operation (v1)" do
    test "parses a well-formed fill" do
      listing_txid = String.duplicate("cd", 32)
      buyer_address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("fill"),
        make_chunk(listing_txid),
        make_chunk("100"),
        make_chunk(buyer_address)
      ]

      assert {:ok, fill} = OrderBookParser.parse(chunks)
      assert fill.version == "1"
      assert fill.op == "fill"
      assert fill.listing_txid == listing_txid
      assert fill.fill_quantity == "100"
      assert fill.buyer_address == buyer_address
    end

    test "returns error when fill_quantity is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("fill"),
        make_chunk(String.duplicate("cd", 32))
      ]

      assert {:error, :missing_fill_quantity} = OrderBookParser.parse(chunks)
    end

    test "returns error when buyer_address is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("1"),
        make_chunk("fill"),
        make_chunk(String.duplicate("cd", 32)),
        make_chunk("100")
      ]

      assert {:error, :missing_buyer_address} = OrderBookParser.parse(chunks)
    end
  end

  describe "parse/1 — versioning" do
    test "rejects a message with no version chunk" do
      # Old-style (pre-version) layout: flag then op directly.
      chunks = [
        make_chunk("orderbook"),
        make_chunk("list"),
        make_chunk(@test_token_id)
      ]

      # "list" is read as the version, which is unsupported.
      assert {:error, :unsupported_version} = OrderBookParser.parse(chunks)
    end

    test "rejects an unknown version rather than guessing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("2"),
        make_chunk("list"),
        make_chunk(@test_token_id)
      ]

      assert {:error, :unsupported_version} = OrderBookParser.parse(chunks)
    end

    test "reports a missing version when only the flag is present" do
      chunks = [make_chunk("orderbook")]

      assert {:error, :missing_version} = OrderBookParser.parse(chunks)
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
        make_chunk("1"),
        make_chunk("unknown_op")
      ]

      assert {:error, :unknown_operation} = OrderBookParser.parse(chunks)
    end

    test "returns error when operation is missing" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("1")
      ]

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
