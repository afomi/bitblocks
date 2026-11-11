defmodule Bitblocks.Interop.PaymentAcceptanceTest do
  @moduledoc """
  Our own `interop-kit/payment-acceptance/v0` vectors
  (`priv/data/interop/payment_acceptance_v0.json`, the record sent to qart to
  read): the script must still build the file byte for byte, the record must
  verify, and each refusal must be refused for its stated reason.
  """
  use ExUnit.Case, async: true

  alias Bitblocks.Interop.{Brc77, Jcs, PaymentAcceptance}

  @path Path.expand("../../../priv/data/interop/payment_acceptance_v0.json", __DIR__)
  @script Path.expand("../../../scripts/payment_acceptance_v0_vectors.exs", __DIR__)
  @external_resource @path
  @doc_map Jason.decode!(File.read!(@path))

  defp unhex(hex), do: Base.decode16!(hex, case: :lower)

  defp as_vector({:error, {:signer_mismatch, signer}}),
    do: %{"reason" => "signer_mismatch", "signer" => signer}

  defp as_vector({:error, {reason, field}}),
    do: %{"reason" => to_string(reason), "field" => field}

  defp as_vector({:error, reason}), do: %{"reason" => to_string(reason)}

  test "the script builds the published file byte for byte" do
    {doc, _} = Code.eval_file(@script)
    assert Jason.encode!(doc, pretty: true) <> "\n" == File.read!(@path)
  end

  test "the test key is the one the file names, and says it's a test key" do
    key = @doc_map["test_key"]
    assert key["warning"] =~ "never send funds"
    assert :crypto.hash(:sha256, key["label"]) == unhex(key["privkey_hex"])

    assert Base.encode16(Brc77.public_key(unhex(key["privkey_hex"])), case: :lower) ==
             key["pubkey"]

    assert Base.decode64!(key["key_id_base64"]) == key["key_id"]
  end

  describe "the record" do
    setup do
      [vector] = @doc_map["acceptance_record"]
      %{vector: vector, expected: vector["expected"]}
    end

    test "its bytes are the canonical form of the record, outputs sorted", %{
      vector: vector,
      expected: expected
    } do
      assert {:ok, record} = PaymentAcceptance.parse(expected["canonical"])
      assert record == vector["record"]
      assert Jcs.encode(vector["record"]) == {:ok, expected["canonical"]}

      txids = Enum.map(record["outputs"], &{&1["txid"], &1["vout"]})
      assert txids == Enum.sort(txids)
      refute Enum.map(vector["outputs_given"], &{&1["txid"], &1["vout"]}) == txids
    end

    test "termsHash is the SHA-256 of the terms, and sha256 of the bytes", %{
      vector: vector,
      expected: expected
    } do
      assert PaymentAcceptance.hash(vector["terms"]) == vector["record"]["termsHash"]
      assert PaymentAcceptance.hash(expected["canonical"]) == expected["sha256"]
    end

    test "it is BRC-77 signed by acceptedBy over the exact bytes", %{expected: expected} do
      envelope = unhex(expected["envelope_hex"])
      assert {:ok, signer} = Brc77.verify(expected["canonical"], envelope)
      assert Base.encode16(signer, case: :lower) == @doc_map["test_key"]["pubkey"]
      assert {:ok, %{"acceptedBy" => by}} = PaymentAcceptance.verify(expected["signed"])
      assert by == @doc_map["test_key"]["pubkey"]
    end

    test "signing refuses a key that isn't acceptedBy", %{expected: expected} do
      other = :crypto.hash(:sha256, "not the acceptedBy key")

      assert PaymentAcceptance.sign(expected["canonical"], other, :binary.copy(<<1>>, 32)) ==
               {:error, :signer_mismatch}
    end
  end

  describe "refusals" do
    for vector <- Jason.decode!(File.read!(@path))["refusals"] do
      @vector vector
      test "#{vector["id"]}" do
        assert as_vector(PaymentAcceptance.verify(@vector["signed"])) == @vector["expected"]
      end
    end

    test "the carrier must be exactly body and signature" do
      [vector] = @doc_map["acceptance_record"]
      signed = Jason.decode!(vector["expected"]["signed"])

      assert PaymentAcceptance.verify(Map.put(signed, "extra", "x")) == {:error, :malformed}
      assert PaymentAcceptance.verify("not json") == {:error, :malformed}

      assert PaymentAcceptance.verify(%{signed | "signature" => "%%%"}) ==
               {:error, :malformed_envelope}
    end
  end

  describe "Jcs" do
    test "sorts members by UTF-16 code units, not code points" do
      # U+1F600 is D83D DE00 in UTF-16, so it sorts before U+E000.
      assert Jcs.encode!(%{"\u{E000}" => 1, "\u{1F600}" => 2}) ==
               ~s({"\u{1F600}":2,"\u{E000}":1})
    end

    test "escapes as JSON.stringify does, control characters in lowercase hex" do
      assert Jcs.encode!("a\"b\\c\b\f\n\r\t\u001f\u007fé") ==
               ~S("a\"b\\c\b\f\n\r\t\u001f) <> "\u007fé\""
    end

    test "holds integers to 2^53 - 1 either way and refuses past it" do
      limit = Jcs.limit()
      assert Jcs.encode!([limit, -limit]) == "[9007199254740991,-9007199254740991]"
      assert Jcs.encode(limit + 1) == {:error, :integer_out_of_range}
      assert Jcs.decode("-9007199254740992") == {:error, :integer_out_of_range}
    end

    test "refuses what isn't already canonical" do
      assert Jcs.decode(~s({"b":1,"a":2})) == {:error, :not_canonical}
      assert Jcs.decode(~s("\\u0041")) == {:error, :not_canonical}
      assert Jcs.decode("-0") == {:error, :not_canonical}
      assert Jcs.decode("1.0") == {:error, :float}
      assert Jcs.decode("[true]") == {:error, :boolean}
      assert Jcs.decode(~s({"a":{"x":1,"x":1}})) == {:error, :duplicate_key}
      assert Jcs.decode("{") == {:error, :invalid_json}
      assert Jcs.decode(~s({"a":[1,null,"x"]})) == {:ok, %{"a" => [1, nil, "x"]}}
    end
  end
end
