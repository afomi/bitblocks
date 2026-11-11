defmodule Bitblocks.Interop.ReceiptV2VectorsTest do
  @moduledoc """
  Bitblocks as the second reader of qart's `receipt_v2_v1` vectors
  (`priv/data/interop/receipt_v2_v1.json`, copied unchanged from qart's
  `docs/vectors/receipt_v2_v1.json` at d28bacdf; afomi/qart#242).

  Set 6, `acceptance_record`, is the one that names our format: its exact
  canonical bytes must parse as an `interop-kit/payment-acceptance/v0` record,
  carry a BRC-77 signature by `acceptedBy`, and hash to the receipt's
  `acceptanceHash`. The other sets exercise the same readers: the restricted
  RFC 8785 form (1, 2), BRC-77 (4), the MAP anchor (5) and AIP authorship (7).
  Set 3 is receipt_v2's own commitment, which we don't index.
  """
  use ExUnit.Case, async: true

  alias Bitblocks.Aip
  alias Bitblocks.Interop.{Brc77, Jcs, PaymentAcceptance}
  alias Bitblocks.MapParser

  @path Path.expand("../../../priv/data/interop/receipt_v2_v1.json", __DIR__)
  @external_resource @path
  @bytes File.read!(@path)
  @doc_map Jason.decode!(@bytes)
  @doc_map_brc77_vectors @doc_map["brc77"]["vectors"]

  # qart's file as qart wrote it; a change here means it was re-derived or edited.
  @sha256 "e7ef288efb9d1c844da84fcfc7f17c7fce91960f848865e1d14cc7ba7dee8ae7"

  defp unhex(hex), do: Base.decode16!(hex, case: :lower)
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp chunks(script_hex), do: BSV.Script.from_binary!(script_hex, encoding: :hex).chunks

  test "the file is qart's, unchanged" do
    assert hex(:crypto.hash(:sha256, @bytes)) == @sha256
    assert @doc_map["name"] == "receipt_v2_v1"
  end

  describe "set 6, acceptance_record" do
    for vector <- Jason.decode!(File.read!(@path))["acceptance_record"] do
      @vector vector
      test "#{vector["id"]}: reads as our v0 record, signed by acceptedBy, hashed to acceptanceHash" do
        expected = @vector["expected"]
        canonical = expected["canonical"]

        # The bytes are already canonical, and are the record qart describes.
        assert {:ok, record} = PaymentAcceptance.parse(canonical)
        assert record == @vector["record"]
        assert Jcs.encode(@vector["record"]) == {:ok, canonical}

        # BRC-77 over the exact bytes, by the acceptedBy key.
        envelope = unhex(expected["envelope_hex"])
        assert {:ok, signer} = Brc77.verify(canonical, envelope)
        assert hex(signer) == record["acceptedBy"]

        signed = Jason.decode!(expected["signed"])
        assert signed["body"] == canonical
        assert Base.decode64!(signed["signature"]) == envelope
        assert PaymentAcceptance.verify(expected["signed"]) == {:ok, record}

        # SHA-256 of the bytes is the receipt's acceptanceHash.
        assert PaymentAcceptance.hash(canonical) == expected["sha256"]
        assert PaymentAcceptance.hash(canonical) == expected["receipt_acceptance_hash"]

        [full | _] = @doc_map_brc77_vectors
        assert Jason.decode!(full["canonical"])["acceptanceHash"] == expected["sha256"]
      end
    end

    test "our signer makes qart's envelope byte for byte from the same key and keyID" do
      %{"issuer_privkey_hex" => priv, "key_id_base64" => key_id} = @doc_map["brc77"]
      [vector] = @doc_map["acceptance_record"]
      expected = vector["expected"]

      assert {:ok, %{"body" => body, "signature" => signature}} =
               PaymentAcceptance.sign(expected["canonical"], unhex(priv), Base.decode64!(key_id))

      assert body == expected["canonical"]
      assert hex(Base.decode64!(signature)) == expected["envelope_hex"]
    end

    test "a changed byte in qart's record fails its signature" do
      [vector] = @doc_map["acceptance_record"]
      signed = Jason.decode!(vector["expected"]["signed"])
      tampered = String.replace(signed["body"], "\"satoshis\":1300", "\"satoshis\":1301")

      assert PaymentAcceptance.verify(%{signed | "body" => tampered}) ==
               {:error, :signature_fails}
    end
  end

  describe "set 1, canonical_form" do
    for vector <- Jason.decode!(File.read!(@path))["canonical_form"] do
      @vector vector
      test "#{vector["id"]}" do
        canonical = @vector["expected"]["canonical"]
        assert Jcs.encode(Jason.decode!(@vector["input"])) == {:ok, canonical}
        assert {:ok, _} = Jcs.decode(canonical)
      end
    end
  end

  describe "set 2, refusals" do
    # missing_field and unknown_field are receipt_v2's own schema, which we
    # don't read; our record's equivalents are in payment_acceptance_test.exs.
    for vector <- Jason.decode!(File.read!(@path))["refusals"],
        vector["expected"]["reason"] not in ["missing_field", "unknown_field"] do
      @vector vector
      test "#{vector["id"]}" do
        assert Jcs.decode(@vector["input"]) ==
                 {:error, String.to_existing_atom(@vector["expected"]["reason"])}
      end
    end
  end

  describe "set 4, brc77" do
    test "issuer-signs-full: verifies, and our signer makes the same envelope" do
      %{"issuer" => issuer, "issuer_privkey_hex" => priv, "key_id_base64" => key_id} =
        @doc_map["brc77"]

      vector = Enum.find(@doc_map_brc77_vectors, &(&1["id"] == "issuer-signs-full"))
      envelope = unhex(vector["expected"]["envelope_hex"])

      assert {:ok, signer} = Brc77.verify(vector["canonical"], envelope)
      assert hex(signer) == issuer
      assert hex(Brc77.public_key(unhex(priv))) == issuer
      assert Brc77.sign(vector["canonical"], unhex(priv), Base.decode64!(key_id)) == envelope
    end

    test "one-byte-changed: the signature fails" do
      vector = Enum.find(@doc_map_brc77_vectors, &(&1["id"] == "one-byte-changed"))
      signed = Jason.decode!(vector["signed"])

      assert Brc77.verify(signed["body"], Base.decode64!(signed["signature"])) ==
               {:error, :signature_fails}
    end

    test "another-signer: a good signature, but not by issuedBy" do
      vector = Enum.find(@doc_map_brc77_vectors, &(&1["id"] == "another-signer"))
      signed = Jason.decode!(vector["signed"])

      assert {:ok, signer} = Brc77.verify(signed["body"], Base.decode64!(signed["signature"]))
      assert hex(signer) == vector["expected"]["signer"]
      refute hex(signer) == Jason.decode!(signed["body"])["issuedBy"]
    end
  end

  describe "set 5, anchor" do
    for vector <- Jason.decode!(File.read!(@path))["anchor"] do
      @vector vector
      test "#{vector["id"]}: our MAP parser reads the commitment and nothing else" do
        expected = @vector["expected"]

        assert [:OP_FALSE, :OP_RETURN | cells] = chunks(expected["script_hex"])
        assert cells == expected["cells"]

        assert {:ok, %{action: :set, app: "qart", keys: keys}} =
                 MapParser.parse_script(expected["script_hex"])

        assert keys == expected["parse"]
        assert keys["commitment"] == @vector["commitment"]
      end
    end
  end

  describe "set 7, receipt_v1_authorship" do
    for vector <- Jason.decode!(File.read!(@path))["receipt_v1_authorship"] do
      @vector vector
      test "#{vector["id"]}: our AIP reader reports the expected author" do
        expected = @vector["expected"]

        want =
          Map.new(expected["author"], fn
            {"status", status} -> {:status, String.to_atom(status)}
            {key, value} -> {String.to_atom(key), value}
          end)

        assert Aip.author(chunks(expected["script_hex"])) == want
      end
    end
  end
end
