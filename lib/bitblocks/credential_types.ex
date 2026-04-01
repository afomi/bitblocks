defmodule Bitblocks.CredentialTypes do
  @moduledoc """
  Defines Verifiable Credential types for on-chain identity.

  Each credential type specifies the required claims, VC type array,
  and schema for its credentialSubject.
  """

  @doc """
  Returns the VC claims structure for a PublicOfficialCredential.

  ## Fields

    * `:holder_did` - DID of the public official (required)
    * `:name` - Full name (required)
    * `:office` - Public office held (required)
    * `:jurisdiction` - Jurisdiction (e.g., "City of Portland, OR")
    * `:term_start` - ISO date for term start
    * `:term_end` - ISO date for term end
    * `:website` - Official website
  """
  def public_official(opts) do
    holder_did = Keyword.fetch!(opts, :holder_did)
    name = Keyword.fetch!(opts, :name)
    office = Keyword.fetch!(opts, :office)

    subject = %{
      "id" => holder_did,
      "name" => name,
      "office" => office
    }

    subject = put_if(subject, "jurisdiction", Keyword.get(opts, :jurisdiction))
    subject = put_if(subject, "termStart", Keyword.get(opts, :term_start))
    subject = put_if(subject, "termEnd", Keyword.get(opts, :term_end))
    subject = put_if(subject, "website", Keyword.get(opts, :website))

    %{
      "@context" => ["https://www.w3.org/2018/credentials/v1"],
      "type" => ["VerifiableCredential", "PublicOfficialCredential"],
      "credentialSubject" => subject
    }
  end

  @doc """
  Returns the VC claims structure for a DriverLicenseCredential.
  """
  def driver_license(opts) do
    holder_did = Keyword.fetch!(opts, :holder_did)
    name = Keyword.fetch!(opts, :name)
    license_number = Keyword.fetch!(opts, :license_number)

    %{
      "@context" => ["https://www.w3.org/2018/credentials/v1"],
      "type" => ["VerifiableCredential", "DriverLicenseCredential"],
      "credentialSubject" => %{
        "id" => holder_did,
        "name" => name,
        "licenseNumber" => license_number
      }
    }
  end

  @doc """
  Lists all available credential types with descriptions.
  """
  def available_types do
    [
      %{
        id: "public_official",
        name: "Public Official",
        description: "Credential for elected or appointed public officials claiming their profile"
      },
      %{
        id: "driver_license",
        name: "Driver License",
        description: "Driver's license credential"
      }
    ]
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
