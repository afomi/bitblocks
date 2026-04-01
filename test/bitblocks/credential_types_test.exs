defmodule Bitblocks.CredentialTypesTest do
  use ExUnit.Case, async: true

  alias Bitblocks.CredentialTypes

  describe "public_official/1" do
    test "generates PublicOfficialCredential VC claims" do
      vc = CredentialTypes.public_official(
        holder_did: "did:web:portland.gov:officials:mayor",
        name: "Ted Wheeler",
        office: "Mayor",
        jurisdiction: "City of Portland, OR",
        term_start: "2021-01-01",
        term_end: "2025-01-01",
        website: "https://portland.gov/mayor"
      )

      assert "PublicOfficialCredential" in vc["type"]
      assert "VerifiableCredential" in vc["type"]

      subject = vc["credentialSubject"]
      assert subject["id"] == "did:web:portland.gov:officials:mayor"
      assert subject["name"] == "Ted Wheeler"
      assert subject["office"] == "Mayor"
      assert subject["jurisdiction"] == "City of Portland, OR"
      assert subject["termStart"] == "2021-01-01"
      assert subject["termEnd"] == "2025-01-01"
      assert subject["website"] == "https://portland.gov/mayor"
    end

    test "omits optional fields when not provided" do
      vc = CredentialTypes.public_official(
        holder_did: "did:web:example.com",
        name: "Minimal Official",
        office: "Council Member"
      )

      subject = vc["credentialSubject"]
      assert subject["name"] == "Minimal Official"
      assert subject["office"] == "Council Member"
      refute Map.has_key?(subject, "jurisdiction")
      refute Map.has_key?(subject, "termStart")
    end
  end

  describe "driver_license/1" do
    test "generates DriverLicenseCredential VC claims" do
      vc = CredentialTypes.driver_license(
        holder_did: "did:web:ryanwold.net",
        name: "Ryan Wold",
        license_number: "D-123-456-CA"
      )

      assert "DriverLicenseCredential" in vc["type"]
      assert vc["credentialSubject"]["licenseNumber"] == "D-123-456-CA"
    end
  end

  describe "available_types/0" do
    test "lists all credential types" do
      types = CredentialTypes.available_types()
      assert length(types) == 2

      ids = Enum.map(types, & &1.id)
      assert "public_official" in ids
      assert "driver_license" in ids
    end
  end
end
