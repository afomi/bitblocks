defmodule Bitblocks.VcardDID do
  @moduledoc """
  Generates DID documents with vCard-compatible service endpoints.

  Bridges W3C DID documents with vCard contact information,
  enabling on-chain identity that includes structured contact data.
  """

  @doc """
  Generates a DID document with vcard service fields.

  ## Options

    * `:did` - The DID identifier (required, e.g., "did:web:ryanwold.net")
    * `:pub_jwk` - Public JWK map for verification method (required)
    * `:fn` - Full name (required)
    * `:org` - Organization name
    * `:email` - Email address
    * `:tel` - Phone number
    * `:url` - Website URL
    * `:title` - Job title
    * `:note` - Additional notes
    * `:photo_url` - URL to photo

  ## Examples

      iex> pub_jwk = %{"kty" => "EC", "crv" => "P-256", "x" => "...", "y" => "..."}
      iex> {:ok, doc} = Bitblocks.VcardDID.generate(did: "did:web:ryanwold.net", pub_jwk: pub_jwk, fn: "Ryan Wold")
      iex> doc["id"]
      "did:web:ryanwold.net"
  """
  def generate(opts) do
    did = Keyword.fetch!(opts, :did)
    pub_jwk = Keyword.fetch!(opts, :pub_jwk)
    full_name = Keyword.fetch!(opts, :fn)

    kid = did <> "#key-1"

    vcard_service = build_vcard_service(did, opts)

    did_doc = %{
      "@context" => [
        "https://www.w3.org/ns/did/v1",
        "https://w3id.org/security/suites/jws-2020/v1"
      ],
      "id" => did,
      "verificationMethod" => [
        %{
          "id" => kid,
          "type" => "JsonWebKey2020",
          "controller" => did,
          "publicKeyJwk" => pub_jwk
        }
      ],
      "assertionMethod" => [kid],
      "authentication" => [kid],
      "service" => [vcard_service]
    }

    vcard_text = build_vcard_text(full_name, opts)

    {:ok, %{did_doc: did_doc, vcard: vcard_text}}
  end

  @doc """
  Builds a vCard text representation from DID options.
  """
  def build_vcard_text(full_name, opts) do
    lines = [
      "BEGIN:VCARD",
      "VERSION:4.0",
      "FN:#{full_name}"
    ]

    lines = if org = Keyword.get(opts, :org), do: lines ++ ["ORG:#{org}"], else: lines
    lines = if email = Keyword.get(opts, :email), do: lines ++ ["EMAIL:#{email}"], else: lines
    lines = if tel = Keyword.get(opts, :tel), do: lines ++ ["TEL:#{tel}"], else: lines
    lines = if url = Keyword.get(opts, :url), do: lines ++ ["URL:#{url}"], else: lines
    lines = if title = Keyword.get(opts, :title), do: lines ++ ["TITLE:#{title}"], else: lines
    lines = if note = Keyword.get(opts, :note), do: lines ++ ["NOTE:#{note}"], else: lines

    lines = if photo = Keyword.get(opts, :photo_url) do
      lines ++ ["PHOTO;MEDIATYPE=image/jpeg:#{photo}"]
    else
      lines
    end

    lines = lines ++ ["END:VCARD"]
    Enum.join(lines, "\n")
  end

  defp build_vcard_service(did, opts) do
    service_endpoint = %{
      "fn" => Keyword.fetch!(opts, :fn)
    }

    service_endpoint =
      Enum.reduce(
        [:org, :email, :tel, :url, :title, :note, :photo_url],
        service_endpoint,
        fn key, acc ->
          case Keyword.get(opts, key) do
            nil -> acc
            val -> Map.put(acc, Atom.to_string(key), val)
          end
        end
      )

    %{
      "id" => did <> "#vcard",
      "type" => "VCardService",
      "serviceEndpoint" => service_endpoint
    }
  end
end
