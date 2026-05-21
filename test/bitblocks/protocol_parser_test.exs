defmodule Bitblocks.ProtocolParserTest do
  use ExUnit.Case, async: true

  alias Bitblocks.ProtocolParser

  # Real mainnet B://+MAP+AIP twetch post
  # txid: 3296ba5078f22e9e6cb1463e8de20fa9459ef149309a6de3ff88e8c0dc24de1a
  @b_map_aip_twetch "6a2231394878696756345179427633744870515663554551797131707a5a56646f4175744c560a68747470733a2f2f7477657463682e6170702f742f336632306533626365346364333731346162653763343764373762313962633938333232666265613761356235343938393735373637343561633734316630610a746578742f706c61696e04746578741f7477657463685f7477746578745f313538303434383334323137332e747874017c223150755161374b36324d694b43747373534c4b79316b683536575755374d74555235035345540b7477646174615f6a736f6e046e756c6c0375726c046e756c6c07636f6d6d656e74046e756c6c076d625f75736572053136333631047479706504706f73740974696d657374616d701131313535373239333231373735353836300361707006747765746368017c22313550636948473232534e4c514a584d6f53556157566937575371633768436676610d424954434f494e5f454344534122314a4c4275744d5a5055377875325055425078656b5463704a4b507a5a756154755a4c58494a367239726f44343878794951334e2f505755756e614843472f4f6e7366686c4f5a686a47365a47566c5663484d414c4641683461514a6e69616f7764597a2b3250544d4d463875526c2b5073723455386a6964346b3d"

  describe "parse_script/2 with Twetch" do
    test "parses real mainnet Twetch post into structured data" do
      assert {:ok, result} = ProtocolParser.parse_script(@b_map_aip_twetch, "Twetch")

      assert result.protocol == "Twetch"
      assert result.type == "post"
      assert result.app == "twetch"
      assert result.user_id == "16361"
      assert result.timestamp == "11557293217755860"
      assert result.content_type == "text/plain"
      assert result.encoding == "text"
      assert result.filename == "twetch_twtext_1580448342173.txt"

      assert String.contains?(
               result.content,
               "https://twetch.app/t/3f20e3bce4cd3714abe7c47d77b19bc98322fbea7a5b549897576745ac741f0a"
             )
    end

    test "converts null MAP values to nil" do
      assert {:ok, result} = ProtocolParser.parse_script(@b_map_aip_twetch, "Twetch")

      assert result.reply_to == nil
      assert result.url == nil
    end

    test "extracts AIP signing data" do
      assert {:ok, result} = ProtocolParser.parse_script(@b_map_aip_twetch, "Twetch")

      assert result.signing_algorithm == "BITCOIN_ECDSA"
      assert result.signing_address == "1JLButMZPU7xu2PUBPxekTcpJKPzZuaTuZ"
      assert is_binary(result.signature)
      assert String.length(result.signature) > 0
    end
  end

  describe "parse_script/2 with unsupported protocol" do
    test "returns error for unknown protocol" do
      assert {:error, :unsupported_protocol} =
               ProtocolParser.parse_script(@b_map_aip_twetch, "Unknown")
    end
  end

  describe "parse_transaction/2" do
    test "returns error when raw is nil" do
      assert {:error, :no_raw_data} = ProtocolParser.parse_transaction(%{raw: nil}, "Twetch")
    end
  end
end
