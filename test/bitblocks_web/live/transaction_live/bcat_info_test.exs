defmodule BitblocksWeb.TransactionLive.BcatInfoTest do
  use ExUnit.Case, async: true

  alias BitblocksWeb.TransactionLive.Show

  @bcat_prefix "15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A"

  defp make_push(utf8, hex \\ nil, length \\ nil) do
    raw = utf8 || ""
    hex = hex || Base.encode16(raw, case: :lower)
    len = length || byte_size(raw)
    %{type: :push_data, utf8: utf8, hex: hex, length: len}
  end

  defp make_32byte_txid do
    hex = String.duplicate("ab", 32)
    %{type: :push_data, utf8: nil, hex: hex, length: 32}
  end

  defp parsed_data(protocols, op_return_data) do
    %{
      protocols: protocols,
      op_returns: [%{data: op_return_data, output_index: 0, satoshis: 0}]
    }
  end

  describe "bcat_info/1" do
    test "returns nil for nil input" do
      assert Show.bcat_info(nil) == nil
    end

    test "returns nil when BCat is not in protocols" do
      data = parsed_data(["B://", "MAP"], [make_push("someaddr")])
      assert Show.bcat_info(data) == nil
    end

    test "returns nil when protocols is empty" do
      data = parsed_data([], [])
      assert Show.bcat_info(data) == nil
    end

    test "classifies BCat chunk tx (second push is 'c')" do
      op_return = [
        make_push(@bcat_prefix),
        make_push("c"),
        %{type: :push_data, utf8: nil, hex: "deadbeef", length: 4}
      ]

      data = parsed_data(["BCat"], op_return)
      assert Show.bcat_info(data) == {:chunk}
    end

    test "classifies BCat head tx with metadata and chunk txids" do
      chunk_txid = make_32byte_txid()

      op_return = [
        make_push(@bcat_prefix),
        make_push(" "),
        make_push("image/png"),
        make_push("binary"),
        make_push("photo.png"),
        make_push(" "),
        chunk_txid
      ]

      data = parsed_data(["BCat"], op_return)
      result = Show.bcat_info(data)

      assert {:head, info} = result
      assert info.mime_type == "image/png"
      assert info.filename == "photo.png"
      assert info.encoding == "binary"
      assert is_nil(info.info)
      assert is_nil(info.flag)
      assert length(info.chunk_txids) == 1
      assert hd(info.chunk_txids) == chunk_txid.hex
    end

    test "strips blank metadata fields (single space → nil)" do
      op_return = [
        make_push(@bcat_prefix),
        make_push(" "),
        make_push(" "),
        make_push(" "),
        make_push(" "),
        make_push(" ")
      ]

      data = parsed_data(["BCat"], op_return)
      result = Show.bcat_info(data)

      assert {:head, info} = result
      assert is_nil(info.info)
      assert is_nil(info.mime_type)
      assert is_nil(info.filename)
      assert info.chunk_txids == []
    end

    test "head with multiple chunk txids" do
      txid1 = make_32byte_txid()
      txid2 = make_32byte_txid()

      op_return = [
        make_push(@bcat_prefix),
        make_push("description"),
        make_push("text/plain"),
        make_push("binary"),
        make_push(" "),
        make_push(" "),
        txid1,
        txid2
      ]

      data = parsed_data(["BCat"], op_return)
      {:head, info} = Show.bcat_info(data)
      assert length(info.chunk_txids) == 2
    end
  end
end
