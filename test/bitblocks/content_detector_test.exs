defmodule Bitblocks.ContentDetectorTest do
  use ExUnit.Case, async: true

  alias Bitblocks.ContentDetector

  describe "detect_b_protocol/1" do
    test "detects B:// protocol with image content" do
      chunks = [
        %{type: :push_data, utf8: "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", hex: "...", length: 10},
        %{type: :push_data, utf8: "raw image data here", hex: "...", length: 5000},
        %{type: :push_data, utf8: "image/png", hex: "...", length: 9},
        %{type: :push_data, utf8: "binary", hex: "...", length: 6},
        %{type: :push_data, utf8: "photo.png", hex: "...", length: 9}
      ]

      result = ContentDetector.detect_b_protocol(chunks)

      assert result.protocol == "B://"
      assert result.content_type == "image/png"
      assert result.media_category == :image
      assert result.encoding == "binary"
      assert result.filename == "photo.png"
    end

    test "returns nil for non-B:// data" do
      chunks = [
        %{type: :push_data, utf8: "some random data", hex: "...", length: 10}
      ]

      assert ContentDetector.detect_b_protocol(chunks) == nil
    end
  end

  describe "detect_ordinal/1" do
    test "detects ordinal inscription with content type" do
      chunks = [
        %{type: :push_data, utf8: "ord", hex: "6f7264", length: 3},
        %{type: :push_data, utf8: "image/jpeg", hex: "...", length: 10},
        %{type: :push_data, utf8: "raw data", hex: "...", length: 5000}
      ]

      result = ContentDetector.detect_ordinal(chunks)

      assert result.protocol == "1Sat Ordinals"
      assert result.content_type == "image/jpeg"
      assert result.media_category == :image
    end

    test "returns nil when no ordinal marker" do
      chunks = [
        %{type: :push_data, utf8: "just text", hex: "...", length: 10}
      ]

      assert ContentDetector.detect_ordinal(chunks) == nil
    end
  end

  describe "categorize_mime/1" do
    test "categorizes image types" do
      assert ContentDetector.categorize_mime("image/png") == :image
      assert ContentDetector.categorize_mime("image/jpeg") == :image
      assert ContentDetector.categorize_mime("image/gif") == :image
      assert ContentDetector.categorize_mime("image/webp") == :image
    end

    test "categorizes text types" do
      assert ContentDetector.categorize_mime("text/plain") == :text
      assert ContentDetector.categorize_mime("text/html") == :text
      assert ContentDetector.categorize_mime("application/json") == :text
    end

    test "categorizes unknown types as other" do
      assert ContentDetector.categorize_mime("application/pdf") == :other
      assert ContentDetector.categorize_mime(nil) == :other
    end
  end

  describe "parse_b_uri/1" do
    test "parses valid b:// URIs" do
      assert {:ok, "abc123"} = ContentDetector.parse_b_uri("b://abc123")
      assert {:ok, "def456"} = ContentDetector.parse_b_uri("B://def456")
    end

    test "rejects invalid URIs" do
      assert {:error, _} = ContentDetector.parse_b_uri("http://example.com")
      assert {:error, _} = ContentDetector.parse_b_uri("b://")
      assert {:error, _} = ContentDetector.parse_b_uri("")
    end
  end

  describe "scan_transactions/1" do
    test "returns empty list for transactions without content" do
      txs = [
        %{txid: "tx1", block_height: 100, outputs: [~s({"value":50})]}
      ]

      assert ContentDetector.scan_transactions(txs) == []
    end

    test "detects B:// content in transaction output" do
      data = Jason.encode!(%{"data" => "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut|imagedata|image/png"})

      txs = [
        %{txid: "tx1", block_height: 100, outputs: [data]}
      ]

      results = ContentDetector.scan_transactions(txs)
      assert length(results) == 1
      assert hd(results).protocol == "B://"
      assert hd(results).txid == "tx1"
    end
  end
end
