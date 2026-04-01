defmodule Bitblocks.VcardDIDTest do
  use ExUnit.Case, async: true

  alias Bitblocks.VcardDID

  @pub_jwk %{
    "kty" => "EC",
    "crv" => "P-256",
    "x" => "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
    "y" => "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
  }

  describe "generate/1" do
    test "generates DID document with vcard service" do
      {:ok, result} =
        VcardDID.generate(
          did: "did:web:ryanwold.net",
          pub_jwk: @pub_jwk,
          fn: "Ryan Wold",
          org: "Bitblocks",
          email: "ryan@example.com"
        )

      doc = result.did_doc

      assert doc["id"] == "did:web:ryanwold.net"
      assert length(doc["verificationMethod"]) == 1

      vm = hd(doc["verificationMethod"])
      assert vm["id"] == "did:web:ryanwold.net#key-1"
      assert vm["publicKeyJwk"] == @pub_jwk

      assert doc["assertionMethod"] == ["did:web:ryanwold.net#key-1"]
      assert doc["authentication"] == ["did:web:ryanwold.net#key-1"]

      # vCard service
      service = hd(doc["service"])
      assert service["type"] == "VCardService"
      assert service["id"] == "did:web:ryanwold.net#vcard"
      assert service["serviceEndpoint"]["fn"] == "Ryan Wold"
      assert service["serviceEndpoint"]["org"] == "Bitblocks"
      assert service["serviceEndpoint"]["email"] == "ryan@example.com"
    end

    test "generates vcard text" do
      {:ok, result} =
        VcardDID.generate(
          did: "did:web:example.com",
          pub_jwk: @pub_jwk,
          fn: "Satoshi Nakamoto",
          email: "satoshi@vistomail.com",
          url: "https://bitcoin.org"
        )

      assert result.vcard =~ "BEGIN:VCARD"
      assert result.vcard =~ "VERSION:4.0"
      assert result.vcard =~ "FN:Satoshi Nakamoto"
      assert result.vcard =~ "EMAIL:satoshi@vistomail.com"
      assert result.vcard =~ "URL:https://bitcoin.org"
      assert result.vcard =~ "END:VCARD"
    end

    test "vcard text can be parsed by VcardParser" do
      {:ok, result} =
        VcardDID.generate(
          did: "did:web:example.com",
          pub_jwk: @pub_jwk,
          fn: "Round Trip",
          org: "TestCorp",
          tel: "+1-555-1234"
        )

      {:ok, parsed} = Bitblocks.VcardParser.parse(result.vcard)
      assert Bitblocks.VcardParser.get_field(parsed, "FN") == "Round Trip"
      assert Bitblocks.VcardParser.get_field(parsed, "ORG") == "TestCorp"
      assert Bitblocks.VcardParser.get_field(parsed, "TEL") == "+1-555-1234"
    end

    test "includes optional fields only when provided" do
      {:ok, result} =
        VcardDID.generate(
          did: "did:web:minimal.com",
          pub_jwk: @pub_jwk,
          fn: "Minimal User"
        )

      doc = result.did_doc
      service = hd(doc["service"])
      endpoint = service["serviceEndpoint"]

      assert endpoint["fn"] == "Minimal User"
      refute Map.has_key?(endpoint, "org")
      refute Map.has_key?(endpoint, "email")

      refute result.vcard =~ "ORG:"
      refute result.vcard =~ "EMAIL:"
    end

    test "includes photo_url in vcard and service" do
      {:ok, result} =
        VcardDID.generate(
          did: "did:web:photo.com",
          pub_jwk: @pub_jwk,
          fn: "Photo Person",
          photo_url: "https://example.com/photo.jpg"
        )

      assert result.vcard =~ "PHOTO;MEDIATYPE=image/jpeg:https://example.com/photo.jpg"

      service = hd(result.did_doc["service"])
      assert service["serviceEndpoint"]["photo_url"] == "https://example.com/photo.jpg"
    end
  end

  describe "build_vcard_text/2" do
    test "generates valid vcard with all fields" do
      text =
        VcardDID.build_vcard_text("Full User",
          org: "Corp",
          email: "full@example.com",
          tel: "+1-555-0000",
          url: "https://full.example.com",
          title: "CEO",
          note: "Test user"
        )

      assert text =~ "FN:Full User"
      assert text =~ "ORG:Corp"
      assert text =~ "TITLE:CEO"
      assert text =~ "NOTE:Test user"
    end
  end
end
