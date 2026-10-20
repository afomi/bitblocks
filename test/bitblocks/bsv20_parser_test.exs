defmodule Bitblocks.Bsv20ParserTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Bsv20Parser

  # Build an inscription-envelope chunk list as BSV.Script would hold it:
  # binaries are push-data, atoms are opcodes. A trailing P2PKH is appended to
  # mirror a real 1-sat ordinal output (the envelope precedes the locking script).
  defp envelope(content_type, body, opts \\ []) do
    lead = Keyword.get(opts, :lead, :OP_FALSE)
    ct_tag = Keyword.get(opts, :ct_tag, :OP_1)
    body_tag = Keyword.get(opts, :body_tag, :OP_0)

    [lead, :OP_IF, "ord", ct_tag, content_type, body_tag, body, :OP_ENDIF] ++
      [:OP_DUP, :OP_HASH160, :binary.copy(<<0>>, 20), :OP_EQUALVERIFY, :OP_CHECKSIG]
  end

  defp bsv20(body), do: envelope("application/bsv-20", body)

  describe "parse/1 — BSV-21 (fully indexed)" do
    test "parses a deploy+mint, mapping amt to max and leaving token_id nil" do
      body = ~s({"p":"bsv-20","op":"deploy+mint","amt":"21000000","sym":"MEME","dec":"8"})

      assert {:ok, token} = Bsv20Parser.parse(bsv20(body))
      assert token.standard == "bsv-21"
      assert token.op == "deploy+mint"
      assert token.amt == "21000000"
      # Whole supply minted in one output — max == amt.
      assert token.max == "21000000"
      assert token.sym == "MEME"
      assert token.dec == "8"
      # Stamped downstream once the outpoint is known.
      assert token.token_id == nil
    end

    test "parses an id-based transfer" do
      body = ~s({"p":"bsv-20","op":"transfer","id":"abc123def456_0","amt":"500"})

      assert {:ok, token} = Bsv20Parser.parse(bsv20(body))
      assert token.standard == "bsv-21"
      assert token.op == "transfer"
      assert token.token_id == "abc123def456_0"
      assert token.amt == "500"
    end

    test "deploy+mint missing amt is rejected" do
      body = ~s({"p":"bsv-20","op":"deploy+mint","sym":"NOPE"})
      assert {:error, :missing_amt} = Bsv20Parser.parse(bsv20(body))
    end

    test "coerces a numeric dec to a string" do
      body = ~s({"p":"bsv-20","op":"deploy+mint","amt":"100","dec":0})
      assert {:ok, %{dec: "0"}} = Bsv20Parser.parse(bsv20(body))
    end
  end

  describe "parse/1 — BSV-20 classic (detect-only)" do
    test "parses a ticker deploy" do
      body = ~s({"p":"bsv-20","op":"deploy","tick":"ordi","max":"21000000","lim":"1000"})

      assert {:ok, token} = Bsv20Parser.parse(bsv20(body))
      assert token.standard == "bsv-20"
      assert token.op == "deploy"
      assert token.tick == "ordi"
      assert token.max == "21000000"
      assert token.lim == "1000"
      assert token.token_id == nil
    end

    test "parses a ticker mint" do
      body = ~s({"p":"bsv-20","op":"mint","tick":"ordi","amt":"1000"})

      assert {:ok, token} = Bsv20Parser.parse(bsv20(body))
      assert token.standard == "bsv-20"
      assert token.op == "mint"
      assert token.tick == "ordi"
      assert token.amt == "1000"
    end

    test "a tick-based transfer (no id) is classic, not bsv-21" do
      body = ~s({"p":"bsv-20","op":"transfer","tick":"ordi","amt":"1000"})

      assert {:ok, token} = Bsv20Parser.parse(bsv20(body))
      assert token.standard == "bsv-20"
      assert token.op == "transfer"
      assert token.tick == "ordi"
    end
  end

  describe "parse/1 — envelope tolerance" do
    test "accepts OP_0 as the leading push" do
      body = ~s({"p":"bsv-20","op":"deploy+mint","amt":"1"})
      assert {:ok, %{op: "deploy+mint"}} = Bsv20Parser.parse(bsv20(body) |> replace_lead())
    end

    test "reads fields when body precedes content type" do
      body = ~s({"p":"bsv-20","op":"deploy+mint","amt":"7"})
      # OP_0 <body> then OP_1 <content-type>, still inside the envelope.
      chunks =
        [:OP_FALSE, :OP_IF, "ord", :OP_0, body, :OP_1, "application/bsv-20", :OP_ENDIF]

      assert {:ok, %{amt: "7"}} = Bsv20Parser.parse(chunks)
    end
  end

  describe "parse/1 — rejections" do
    test "rejects a non-bsv-20 content type" do
      body = ~s({"p":"bsv-20","op":"deploy+mint","amt":"1"})
      assert {:error, :not_bsv20} = Bsv20Parser.parse(envelope("text/plain", body))
    end

    test "rejects a script with no inscription envelope" do
      chunks = [:OP_DUP, :OP_HASH160, :binary.copy(<<0>>, 20), :OP_EQUALVERIFY, :OP_CHECKSIG]
      assert {:error, :no_inscription} = Bsv20Parser.parse(chunks)
    end

    test "rejects invalid JSON in the body" do
      assert {:error, :invalid_json} = Bsv20Parser.parse(bsv20("{not json"))
    end

    test "rejects an over-large body without decoding it" do
      big = ~s({"p":"bsv-20","op":"deploy+mint","amt":") <> String.duplicate("9", 5000) <> ~s("})
      assert {:error, :body_too_large} = Bsv20Parser.parse(bsv20(big))
    end

    test "rejects an unknown operation" do
      body = ~s({"p":"bsv-20","op":"burn","tick":"ordi","amt":"1"})
      assert {:error, :unknown_operation} = Bsv20Parser.parse(bsv20(body))
    end

    test "rejects a wrong protocol identifier" do
      body = ~s({"p":"brc-20","op":"deploy+mint","amt":"1"})
      assert {:error, :not_bsv20} = Bsv20Parser.parse(bsv20(body))
    end
  end

  describe "token_inscription?/1" do
    test "true for a bsv-20 inscription" do
      body = ~s({"p":"bsv-20","op":"deploy+mint","amt":"1"})
      assert Bsv20Parser.token_inscription?(bsv20(body))
    end

    test "false for a plain P2PKH script" do
      chunks = [:OP_DUP, :OP_HASH160, :binary.copy(<<0>>, 20), :OP_EQUALVERIFY, :OP_CHECKSIG]
      refute Bsv20Parser.token_inscription?(chunks)
    end

    test "false for a non-bsv-20 inscription" do
      refute Bsv20Parser.token_inscription?(envelope("image/png", "notjson"))
    end
  end

  # Swap the leading OP_FALSE for OP_0 to exercise that branch.
  defp replace_lead([:OP_FALSE | rest]), do: [:OP_0 | rest]
end
