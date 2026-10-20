defmodule Bitblocks.Protocol.HandlersTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Protocol.Handlers
  alias Bitblocks.Script.OpReturn

  defp chunks(binaries) do
    OpReturn.parse_data(%BSV.Script{chunks: [:OP_RETURN | binaries]})
  end

  describe "detect_all/1 parity with the historical hardcoded detection" do
    test "Bitcom address prefixes" do
      assert Handlers.detect_all(chunks(["19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", "content"])) ==
               ["B://"]

      assert Handlers.detect_all(chunks(["15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A", "chunk1"])) ==
               ["BCat"]
    end

    test "piped B:// | MAP | AIP detects all three, in segment order" do
      piped =
        chunks([
          "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut",
          "post content",
          "|",
          "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
          "SET",
          "app",
          "someapp",
          "|",
          "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva",
          "BITCOIN_ECDSA"
        ])

      assert Handlers.detect_all(piped) == ["B://", "MAP", "AIP"]
    end

    test "MAP app=twetch adds Twetch" do
      piped =
        chunks([
          "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
          "SET",
          "app",
          "twetch"
        ])

      assert Handlers.detect_all(piped) == ["MAP", "Twetch"]
    end

    test "exact magic strings win over prefix sniffs (orderbook vs ord)" do
      detected = Handlers.detect_all(chunks(["orderbook", "list", "TOKEN"]))

      # The segment resolves to OrderBook (exact match precedes the ord prefix)…
      assert List.first(detected) == "OrderBook"
      # …but the historical hex sniff also fires: "orderbook" contains hex
      # 6f7264 ("ord"). Preserved for parity with the pre-registry detection.
      assert "1SAT Ordinals" in detected

      assert Handlers.detect_all(chunks(["meta", "pubkey", "txid"])) == ["Metanet"]
    end

    test "ord prefix and hex marker both detect 1SAT Ordinals" do
      assert "1SAT Ordinals" in Handlers.detect_all(chunks(["ordinal-ish"]))
      # binary containing "ord" bytes → hex 6f7264 somewhere in the payload
      assert "1SAT Ordinals" in Handlers.detect_all(chunks([<<0xFF, "ord", 0xFF>>]))
    end

    test "Run envelope by hex prefix" do
      assert "Run" in Handlers.detect_all(chunks(["run", "{}"]))
      refute "Run" in Handlers.detect_all(chunks(["not-first", "run"]))
    end

    test "vCard by joined text" do
      vcard = "BEGIN:VCARD\nVERSION:3.0\nFN:Satoshi\nEND:VCARD"
      assert "vCard" in Handlers.detect_all(chunks([vcard]))
    end

    test "no protocols → empty list" do
      assert Handlers.detect_all(chunks(["just some data"])) == []
    end
  end

  describe "registry lookup and deep-parse dispatch" do
    test "every handler resolves by its name" do
      for handler <- Handlers.all() do
        assert Handlers.get(handler.name()) == handler
      end
    end

    test "parse dispatches to a handler's deep parser" do
      metanet = chunks(["meta", String.duplicate("02", 33), String.duplicate("ab", 32)])
      assert {:ok, %{}} = Handlers.parse(metanet, "Metanet")
    end

    test "parse of an unknown or parserless protocol is unsupported" do
      assert Handlers.parse(chunks(["x"]), "NoSuchProtocol") == {:error, :unsupported_protocol}
      assert Handlers.parse(chunks(["x"]), "B://") == {:error, :unsupported_protocol}
    end
  end
end
