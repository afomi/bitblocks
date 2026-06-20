defmodule Bitblocks.TransactionParserTest do
  use ExUnit.Case, async: true

  alias Bitblocks.TransactionParser

  # Real mainnet transaction fixtures

  # B://+MAP+AIP: twetch post with text content, MAP metadata, and AIP signature
  # txid: 3296ba5078f22e9e6cb1463e8de20fa9459ef149309a6de3ff88e8c0dc24de1a
  @b_map_aip_twetch "6a2231394878696756345179427633744870515663554551797131707a5a56646f4175744c560a68747470733a2f2f7477657463682e6170702f742f336632306533626365346364333731346162653763343764373762313962633938333232666265613761356235343938393735373637343561633734316630610a746578742f706c61696e04746578741f7477657463685f7477746578745f313538303434383334323137332e747874017c223150755161374b36324d694b43747373534c4b79316b683536575755374d74555235035345540b7477646174615f6a736f6e046e756c6c0375726c046e756c6c07636f6d6d656e74046e756c6c076d625f75736572053136333631047479706504706f73740974696d657374616d701131313535373239333231373735353836300361707006747765746368017c22313550636948473232534e4c514a584d6f53556157566937575371633768436676610d424954434f494e5f454344534122314a4c4275744d5a5055377875325055425078656b5463704a4b507a5a756154755a4c58494a367239726f44343878794951334e2f505755756e614843472f4f6e7366686c4f5a686a47365a47566c5663484d414c4641683461514a6e69616f7764597a2b3250544d4d463875526c2b5073723455386a6964346b3d"

  # MAP-only: tonicpow offer_click
  # txid: 32b968bb591dfdc51d97b31bf4affced014207670f22879c3180cb8b3290b794
  @map_only_tonicpow "6a223150755161374b36324d694b43747373534c4b79316b683536575755374d74555235035345540361707008746f6e6963706f7704747970650b6f666665725f636c69636b0f6f666665725f636f6e6669675f6964203935303763653162653532363432396639363733303530613866313731326133"

  describe "detect_protocols/1 with piped OP_RETURN data" do
    test "detects all protocols in a B://+MAP+AIP pipe" do
      chunks = build_piped_chunks([
        {"19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", ["content", "text/plain", "utf-8"]},
        {"1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", ["SET", "app", "test", "type", "post"]},
        {"15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva", ["BITCOIN_ECDSA", "1Addr", "sig"]}
      ])

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      assert "B://" in protocols
      assert "MAP" in protocols
      assert "AIP" in protocols
    end

    test "detects Twetch from MAP app field" do
      chunks = build_piped_chunks([
        {"19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", ["content", "text/plain"]},
        {"1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", ["SET", "app", "twetch", "type", "post"]},
        {"15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva", ["BITCOIN_ECDSA", "1Addr", "sig"]}
      ])

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      assert "Twetch" in protocols
      assert "B://" in protocols
      assert "MAP" in protocols
      assert "AIP" in protocols
    end

    test "single B:// protocol still detected" do
      chunks = [
        %{type: :push_data, utf8: "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", hex: "", length: 0},
        %{type: :push_data, utf8: "hello", hex: "", length: 0},
        %{type: :push_data, utf8: "text/plain", hex: "", length: 0}
      ]

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      assert protocols == ["B://"]
    end

    test "single MAP protocol still detected" do
      chunks = [
        %{type: :push_data, utf8: "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", hex: "", length: 0},
        %{type: :push_data, utf8: "SET", hex: "", length: 0},
        %{type: :push_data, utf8: "app", hex: "", length: 0},
        %{type: :push_data, utf8: "qart", hex: "", length: 0}
      ]

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      assert "MAP" in protocols
    end

    test "does not duplicate protocol names" do
      chunks = build_piped_chunks([
        {"19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", ["content"]},
        {"1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", ["SET", "app", "twetch"]}
      ])

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      assert length(Enum.filter(protocols, &(&1 == "B://"))) == 1
      assert length(Enum.filter(protocols, &(&1 == "MAP"))) == 1
    end

    test "non-twetch MAP app does not add spurious protocol" do
      chunks = build_piped_chunks([
        {"19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", ["content"]},
        {"1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", ["SET", "app", "someother"]}
      ])

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      assert "B://" in protocols
      assert "MAP" in protocols
      refute "Twetch" in protocols
    end
  end

  describe "detect_protocols/1 with Metanet flag" do
    test "detects Metanet from meta flag as first chunk" do
      # Simulated: OP_RETURN "meta" <33-byte-pubkey-hex> <32-byte-parent-txid-hex>
      pubkey_hex = String.duplicate("ab", 33)
      parent_txid_hex = String.duplicate("cd", 32)

      chunks = [
        make_chunk("meta"),
        make_chunk(pubkey_hex),
        make_chunk(parent_txid_hex)
      ]

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      assert "Metanet" in protocols
    end

    test "does not detect Metanet for non-meta first chunk" do
      chunks = [
        make_chunk("notmeta"),
        make_chunk("some data")
      ]

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      refute "Metanet" in protocols
    end

    test "detects Metanet alongside piped protocols" do
      # Metanet node that also pipes MAP metadata
      chunks = build_piped_chunks([
        {"meta", [String.duplicate("ab", 33), String.duplicate("00", 32), "mypage"]},
        {"1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", ["SET", "app", "myblog", "type", "page"]}
      ])

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      assert "Metanet" in protocols
      assert "MAP" in protocols
    end
  end

  describe "detect_protocols/1 with OrderBook flag" do
    test "detects OrderBook from orderbook flag as first chunk" do
      chunks = [
        make_chunk("orderbook"),
        make_chunk("list"),
        make_chunk("token_abc_0"),
        make_chunk("100"),
        make_chunk("5000"),
        make_chunk("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"),
        make_chunk("token_abc:0")
      ]

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      assert "OrderBook" in protocols
    end

    test "does not detect OrderBook for non-orderbook first chunk" do
      chunks = [
        make_chunk("notorderbook"),
        make_chunk("list")
      ]

      protocols = TransactionParser.detect_protocols([%{data: chunks}])

      refute "OrderBook" in protocols
    end
  end

  describe "BCat protocol detection" do
    @bcat_prefix "15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A"

    test "detects BCat head tx (second push is not 'c')" do
      # Head: prefix, info, mime, encoding, filename, flag, then chunk txids
      chunks = [
        make_chunk(@bcat_prefix),
        make_chunk(" "),
        make_chunk("image/png"),
        make_chunk("binary"),
        make_chunk(" "),
        make_chunk(" ")
      ]

      protocols = TransactionParser.detect_protocols([%{data: chunks}])
      assert "BCat" in protocols
    end

    test "detects BCat chunk tx (second push is 'c')" do
      chunks = [
        make_chunk(@bcat_prefix),
        make_chunk("c"),
        %{type: :push_data, utf8: nil, hex: "deadbeef", length: 4}
      ]

      protocols = TransactionParser.detect_protocols([%{data: chunks}])
      assert "BCat" in protocols
    end

    test "does not detect BCat for a different prefix" do
      chunks = [make_chunk("1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"), make_chunk("c")]

      protocols = TransactionParser.detect_protocols([%{data: chunks}])
      refute "BCat" in protocols
    end
  end

  describe "script_analysis_version/0" do
    test "returns version 4 for OrderBook detection" do
      assert TransactionParser.script_analysis_version() == 4
    end
  end

  describe "determine_script_type/1" do
    test "P2PKH" do
      {:ok, s} = BSV.Script.from_binary("76a914" <> String.duplicate("aa", 20) <> "88ac", encoding: :hex)
      assert TransactionParser.determine_script_type(s) == :p2pkh
    end

    test "P2SH" do
      {:ok, s} = BSV.Script.from_binary("a914" <> String.duplicate("bb", 20) <> "87", encoding: :hex)
      assert TransactionParser.determine_script_type(s) == :p2sh
    end

    test "P2PK compressed (33 bytes)" do
      {:ok, s} = BSV.Script.from_binary("21" <> String.duplicate("02", 33) <> "ac", encoding: :hex)
      assert TransactionParser.determine_script_type(s) == :p2pk
    end

    test "P2PK uncompressed (65 bytes)" do
      {:ok, s} = BSV.Script.from_binary("41" <> String.duplicate("04", 65) <> "ac", encoding: :hex)
      assert TransactionParser.determine_script_type(s) == :p2pk
    end

    test "OP_RETURN" do
      {:ok, s} = BSV.Script.from_binary("6a04deadbeef", encoding: :hex)
      assert TransactionParser.determine_script_type(s) == :op_return
    end

    test "OP_FALSE OP_RETURN (segwit-style data carrier)" do
      s = %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "data"]}
      assert TransactionParser.determine_script_type(s) == :op_return
    end

    test "multisig 1-of-2" do
      s = %BSV.Script{chunks: [:OP_TRUE, <<0::8*33>>, <<1::8*33>>, :OP_2, :OP_CHECKMULTISIG]}
      assert TransactionParser.determine_script_type(s) == :multisig
    end

    test "multisig 2-of-3" do
      s = %BSV.Script{chunks: [:OP_2, <<0::8*33>>, <<1::8*33>>, <<2::8*33>>, :OP_3, :OP_CHECKMULTISIG]}
      assert TransactionParser.determine_script_type(s) == :multisig
    end

    test "unknown script returns :unknown" do
      s = %BSV.Script{chunks: [:OP_NOP]}
      assert TransactionParser.determine_script_type(s) == :unknown
    end

    test "empty script returns :unknown" do
      s = %BSV.Script{chunks: []}
      assert TransactionParser.determine_script_type(s) == :unknown
    end
  end

  describe "extract_script_fields/1" do
    test "P2PKH returns pubkey_hash" do
      pkh = String.duplicate("aa", 20)
      {:ok, s} = BSV.Script.from_binary("76a914" <> pkh <> "88ac", encoding: :hex)
      assert %{type: :p2pkh, pubkey_hash: ^pkh} = TransactionParser.extract_script_fields(s)
    end

    test "P2SH returns script_hash" do
      sh = String.duplicate("bb", 20)
      {:ok, s} = BSV.Script.from_binary("a914" <> sh <> "87", encoding: :hex)
      assert %{type: :p2sh, script_hash: ^sh} = TransactionParser.extract_script_fields(s)
    end

    test "P2PK returns pubkey" do
      pk = String.duplicate("02", 33)
      {:ok, s} = BSV.Script.from_binary("21" <> pk <> "ac", encoding: :hex)
      assert %{type: :p2pk, pubkey: ^pk} = TransactionParser.extract_script_fields(s)
    end

    test "multisig returns m, n, and pubkeys" do
      pk1 = <<0::8*33>>
      pk2 = <<1::8*33>>
      s = %BSV.Script{chunks: [:OP_TRUE, pk1, pk2, :OP_2, :OP_CHECKMULTISIG]}
      fields = TransactionParser.extract_script_fields(s)
      assert fields.type == :multisig
      assert fields.m == 1
      assert fields.n == 2
      assert length(fields.pubkeys) == 2
      assert fields.pubkeys == [Base.encode16(pk1, case: :lower), Base.encode16(pk2, case: :lower)]
    end

    test "OP_RETURN returns data chunks" do
      {:ok, s} = BSV.Script.from_binary("6a04deadbeef", encoding: :hex)
      assert %{type: :op_return, data: [%{type: :push_data, hex: "deadbeef"}]} =
               TransactionParser.extract_script_fields(s)
    end

    test "unknown returns asm string" do
      s = %BSV.Script{chunks: [:OP_NOP]}
      assert %{type: :unknown, asm: asm} = TransactionParser.extract_script_fields(s)
      assert is_binary(asm)
    end
  end

  describe "is_op_return?/1" do
    test "OP_RETURN output is detected" do
      {:ok, script} = BSV.Script.from_binary("6a04deadbeef", encoding: :hex)
      out = %BSV.TxOut{script: script, satoshis: 0}
      assert TransactionParser.is_op_return?(out)
    end

    test "P2PKH output is not OP_RETURN" do
      {:ok, script} = BSV.Script.from_binary("76a914" <> String.duplicate("aa", 20) <> "88ac", encoding: :hex)
      out = %BSV.TxOut{script: script, satoshis: 1000}
      refute TransactionParser.is_op_return?(out)
    end
  end

  # Builds a list of parsed OP_RETURN data chunks with pipe separators
  # from a list of {protocol_address, data_chunks} tuples.
  defp build_piped_chunks(segments) do
    segments
    |> Enum.map(fn {addr, data} ->
      [make_chunk(addr) | Enum.map(data, &make_chunk/1)]
    end)
    |> Enum.intersperse([make_chunk("|")])
    |> List.flatten()
  end

  defp make_chunk(text) do
    %{type: :push_data, utf8: text, hex: Base.encode16(text, case: :lower), length: byte_size(text)}
  end
end
