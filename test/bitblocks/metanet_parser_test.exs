defmodule Bitblocks.MetanetParserTest do
  use ExUnit.Case, async: true

  alias Bitblocks.MetanetParser

  # Simulated compressed pubkey (33 bytes = 66 hex chars)
  @test_pubkey_hex "03" <> String.duplicate("ab", 32)
  # Simulated parent txid (32 bytes = 64 hex chars)
  @test_parent_txid String.duplicate("cd", 32)

  describe "parse/1" do
    test "parses a well-formed Metanet node with all fields" do
      chunks = [
        make_chunk("meta"),
        make_hex_chunk(@test_pubkey_hex, 33),
        make_hex_chunk(@test_parent_txid, 32),
        make_chunk("my-page"),
        make_chunk("text/plain"),
        make_chunk("Hello, Metanet!")
      ]

      assert {:ok, node} = MetanetParser.parse(chunks)
      assert node.p_node == @test_pubkey_hex
      assert node.parent_txid == @test_parent_txid
      assert node.is_root == false
      assert node.name == "my-page"
      assert node.content_type == "text/plain"
      assert node.content == "Hello, Metanet!"
    end

    test "parses a root node with empty parent txid" do
      chunks = [
        make_chunk("meta"),
        make_hex_chunk(@test_pubkey_hex, 33),
        %{type: :push_data, hex: "", utf8: nil, length: 0}
      ]

      assert {:ok, node} = MetanetParser.parse(chunks)
      assert node.parent_txid == nil
      assert node.is_root == true
    end

    test "parses a root node with all-zero parent txid" do
      chunks = [
        make_chunk("meta"),
        make_hex_chunk(@test_pubkey_hex, 33),
        make_hex_chunk(String.duplicate("00", 32), 32)
      ]

      assert {:ok, node} = MetanetParser.parse(chunks)
      assert node.parent_txid == nil
      assert node.is_root == true
    end

    test "handles missing optional fields" do
      chunks = [
        make_chunk("meta"),
        make_hex_chunk(@test_pubkey_hex, 33),
        make_hex_chunk(@test_parent_txid, 32)
      ]

      assert {:ok, node} = MetanetParser.parse(chunks)
      assert node.name == nil
      assert node.content_type == nil
      assert node.content == nil
    end

    test "returns error for non-Metanet data" do
      chunks = [
        make_chunk("notmeta"),
        make_chunk("some data")
      ]

      assert {:error, :not_metanet} = MetanetParser.parse(chunks)
    end

    test "returns error when pubkey is missing" do
      chunks = [make_chunk("meta")]

      assert {:error, :missing_pubkey} = MetanetParser.parse(chunks)
    end
  end

  describe "node_id/2" do
    test "computes SHA256 of P_node || TxID" do
      txid = String.duplicate("ef", 32)
      result = MetanetParser.node_id(@test_pubkey_hex, txid)

      assert is_binary(result)
      # SHA256 produces 32 bytes = 64 hex chars
      assert byte_size(result) == 64
    end

    test "different inputs produce different node IDs" do
      txid_a = String.duplicate("aa", 32)
      txid_b = String.duplicate("bb", 32)

      id_a = MetanetParser.node_id(@test_pubkey_hex, txid_a)
      id_b = MetanetParser.node_id(@test_pubkey_hex, txid_b)

      assert id_a != id_b
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

  # Helper: make a push_data chunk from raw hex (binary pubkeys, txids)
  defp make_hex_chunk(hex, byte_length) do
    %{
      type: :push_data,
      utf8: nil,
      hex: hex,
      length: byte_length
    }
  end
end
