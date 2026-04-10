defmodule Bitblocks.MapParserTest do
  use ExUnit.Case, async: true

  alias Bitblocks.MapParser

  # Real transaction fixtures from block 620001 (mainnet)

  # MAP-only: tonicpow offer_click
  # txid: 32b968bb591dfdc51d97b31bf4affced014207670f22879c3180cb8b3290b794
  @map_only_tonicpow "6a223150755161374b36324d694b43747373534c4b79316b683536575755374d74555235035345540361707008746f6e6963706f7704747970650b6f666665725f636c69636b0f6f666665725f636f6e6669675f6964203935303763653162653532363432396639363733303530613866313731326133"

  # B://+MAP+AIP: twetch post with text content, MAP metadata, and AIP signature
  # txid: 3296ba5078f22e9e6cb1463e8de20fa9459ef149309a6de3ff88e8c0dc24de1a
  @b_map_aip_twetch "6a2231394878696756345179427633744870515663554551797131707a5a56646f4175744c560a68747470733a2f2f7477657463682e6170702f742f336632306533626365346364333731346162653763343764373762313962633938333232666265613761356235343938393735373637343561633734316630610a746578742f706c61696e04746578741f7477657463685f7477746578745f313538303434383334323137332e747874017c223150755161374b36324d694b43747373534c4b79316b683536575755374d74555235035345540b7477646174615f6a736f6e046e756c6c0375726c046e756c6c07636f6d6d656e74046e756c6c076d625f75736572053136333631047479706504706f73740974696d657374616d701131313535373239333231373735353836300361707006747765746368017c22313550636948473232534e4c514a584d6f53556157566937575371633768436676610d424954434f494e5f454344534122314a4c4275744d5a5055377875325055425078656b5463704a4b507a5a756154755a4c58494a367239726f44343878794951334e2f505755756e614843472f4f6e7366686c4f5a686a47365a47566c5663484d414c4641683461514a6e69616f7764597a2b3250544d4d463875526c2b5073723455386a6964346b3d"

  # MAP-only: Bit.sv receipt with piped prefix
  # txid: d0d5ff9b201250676be403fd64721558661ccc07d6d54238898e421b11783534
  @map_only_receipt "6a22314c38654e754138546f4c474b35615634643564397258554162525a55784b726846017c223150755161374b36324d694b43747373534c4b79316b683536575755374d7455523503534554047479706507726563656970740474786964406130303661303732653661326538383863313332376235386434666265356166373837316362356234636638346166643931323365313132353730313566373004636f737404302e303504756e69740355534403617070064269742e73760974696d657374616d700a31353830343436333134"

  describe "parse/1 with pre-decoded chunks" do
    test "parses MAP SET with key-value pairs" do
      chunks = [
        "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
        "SET",
        "app",
        "qart",
        "type",
        "listing",
        "title",
        "Test Item"
      ]

      assert {:ok, result} = MapParser.parse(chunks)
      assert result.action == :set
      assert result.app == "qart"
      assert result.keys["app"] == "qart"
      assert result.keys["type"] == "listing"
      assert result.keys["title"] == "Test Item"
    end

    test "parses MAP DELETE" do
      chunks = [
        "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
        "DELETE",
        "old_key",
        "another_key"
      ]

      assert {:ok, result} = MapParser.parse(chunks)
      assert result.action == :delete
      assert Map.has_key?(result.keys, "old_key")
      assert Map.has_key?(result.keys, "another_key")
    end

    test "parses piped B:// + MAP + AIP chunks" do
      chunks = [
        "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut",
        "hello world",
        "text/plain",
        "utf-8",
        "|",
        "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
        "SET",
        "app",
        "qart",
        "type",
        "post",
        "|",
        "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva",
        "BITCOIN_ECDSA",
        "1Address...",
        "signature..."
      ]

      assert {:ok, result} = MapParser.parse(chunks)
      assert result.action == :set
      assert result.app == "qart"
      assert result.keys["type"] == "post"
    end

    test "returns error when no MAP segment present" do
      chunks = [
        "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut",
        "hello",
        "text/plain"
      ]

      assert {:error, :no_map_segment} = MapParser.parse(chunks)
    end

    test "returns error for unknown MAP action" do
      chunks = [
        "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
        "UNKNOWN_ACTION",
        "key",
        "value"
      ]

      assert {:error, :unknown_map_action} = MapParser.parse(chunks)
    end

    test "handles odd number of key-value pairs gracefully" do
      chunks = [
        "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
        "SET",
        "app",
        "test",
        "orphan_key"
      ]

      assert {:ok, result} = MapParser.parse(chunks)
      assert result.keys["app"] == "test"
      assert result.keys["orphan_key"] == nil
    end
  end

  describe "parse_script/1 with real mainnet transactions" do
    test "parses MAP-only tonicpow offer_click" do
      assert {:ok, result} = MapParser.parse_script(@map_only_tonicpow)
      assert result.action == :set
      assert result.app == "tonicpow"
      assert result.keys["type"] == "offer_click"
      assert result.keys["offer_config_id"] == "9507ce1be526429f9673050a8f1712a3"
    end

    test "parses B://+MAP+AIP twetch post" do
      assert {:ok, result} = MapParser.parse_script(@b_map_aip_twetch)
      assert result.action == :set
      assert result.app == "twetch"
      assert result.keys["type"] == "post"
      assert result.keys["mb_user"] == "16361"
      assert result.keys["comment"] == "null"
      assert result.keys["timestamp"] == "11557293217755860"
    end

    test "parses MAP-only Bit.sv receipt with piped prefix" do
      assert {:ok, result} = MapParser.parse_script(@map_only_receipt)
      assert result.action == :set
      assert result.app == "Bit.sv"
      assert result.keys["type"] == "receipt"
      assert result.keys["cost"] == "0.05"
      assert result.keys["unit"] == "USD"
      assert result.keys["timestamp"] == "1580446314"
    end
  end

  describe "extract_protocols/1" do
    test "extracts all protocol segments from piped transaction" do
      chunks = [
        "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut",
        "content",
        "text/plain",
        "|",
        "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
        "SET",
        "app",
        "test",
        "|",
        "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva",
        "BITCOIN_ECDSA",
        "addr",
        "sig"
      ]

      protocols = MapParser.extract_protocols(chunks)

      assert [
               {"19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", ["content", "text/plain"]},
               {"1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", ["SET", "app", "test"]},
               {"15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva", ["BITCOIN_ECDSA", "addr", "sig"]}
             ] = protocols
    end

    test "handles single protocol without pipes" do
      chunks = [
        "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
        "SET",
        "app",
        "qart"
      ]

      protocols = MapParser.extract_protocols(chunks)
      assert [{"1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", ["SET", "app", "qart"]}] = protocols
    end
  end
end
