defmodule BitblocksWeb.TxSummaryTest do
  use ExUnit.Case, async: true

  alias BitblocksWeb.TxSummary

  defp token_tx(json) do
    script = %BSV.Script{
      chunks: [
        :OP_FALSE,
        :OP_IF,
        "ord",
        :OP_1,
        "application/bsv-20",
        :OP_FALSE,
        json,
        :OP_ENDIF
      ]
    }

    %BSV.Tx{inputs: [], outputs: [%BSV.TxOut{satoshis: 1, script: script}]}
  end

  describe "state/2" do
    test "tells a missing body from one that won't decode" do
      assert TxSummary.state(%{raw: nil}, nil) == :not_downloaded
      assert TxSummary.state(%{raw: ""}, nil) == :not_downloaded
      assert TxSummary.state(%{raw: "00"}, nil) == :undecodable
      assert TxSummary.state(%{raw: "00"}, %BSV.Tx{}) == :decoded
    end
  end

  describe "protocol_links/4" do
    test "a BSV-21 mint links to itself as a token" do
      tx = token_tx(~s({"p":"bsv-20","op":"deploy+mint","amt":"100","sym":"X"}))

      assert [%{label: "BSV-21 token", path: "/tokens/abc_0"}] =
               TxSummary.protocol_links(%{txid: "abc", protocols: ["BSV20"]}, tx, [], nil)
    end

    test "a BSV-21 transfer links to the token it names" do
      tx = token_tx(~s({"p":"bsv-20","op":"transfer","id":"def_1","amt":"5"}))

      assert [%{path: "/tokens/def_1"}] =
               TxSummary.protocol_links(%{txid: "abc", protocols: ["BSV20"]}, tx, [], nil)
    end

    test "a tag with no decoded token still reaches the token list" do
      assert [%{label: "Token", path: "/tokens"}] =
               TxSummary.protocol_links(%{txid: "abc", protocols: ["BSV20"]}, nil, [], nil)
    end

    test "a collection links to its page, and a page appears once" do
      facts = %{collections: [%{slug: "rexxies", name: "Rexxies"}]}

      assert [%{label: "Run"}, %{label: "Rexxies", path: "/collections/rexxies"}] =
               TxSummary.protocol_links(%{txid: "abc", protocols: ["Run"]}, nil, ["Run"], facts)
    end

    test "a prefix protocol with no page of its own links to its namespace" do
      assert [%{path: "/bitcom/15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A"}] =
               TxSummary.protocol_links(%{txid: "abc", protocols: ["BCat"]}, nil, [], nil)
    end

    test "a protocol only the registry knows links to the registry" do
      assert [%{label: "Somewhere", path: "/protocols"}] =
               TxSummary.protocol_links(%{txid: "abc", protocols: ["Somewhere"]}, nil, [], nil)
    end
  end

  describe "paid_to/1" do
    test "reads a script with no address as what it is" do
      assert TxSummary.paid_to(nil) == "—"
      assert TxSummary.paid_to(%{type: :op_return}) == "Data"
      assert TxSummary.paid_to(%{type: :multisig, fields: %{m: 2, n: 3}}) == "2-of-3 multisig"
      assert TxSummary.paid_to(%{type: :unknown}) == "Script"
    end
  end
end
