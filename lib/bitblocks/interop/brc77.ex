defmodule Bitblocks.Interop.Brc77 do
  @moduledoc """
  BRC-77 signed messages, verifiable by anyone.

  An envelope is

      42423301 | signer identity key (33) | 00 | keyID (32) | DER signature

  where `00` says the recipient is anyone.
  The signature is ECDSA over SHA-256 of the exact message bytes, deterministic
  (RFC 6979) and low-S, by the signer's BRC-42 child key for the invoice
  `"2-message signing-<base64 keyID>"` with counterparty anyone.
  That is what `@bsv/sdk`'s `SignedMessage.sign`, and a BRC-100 wallet's
  `createSignature` with protocol `[2, "message signing"]`, make.

  ## BRC-42 with counterparty anyone

  "Anyone" is the key whose private scalar is 1, so its public key is `G`.
  The shared secret between the signer and anyone is then the signer's own
  public key, which both sides can compute:

      secret = d·G = P             (signer: d times anyone's G; verifier: 1 times P)
      h      = HMAC-SHA256(key: compressed(secret), data: invoice)
      child private key = d + h mod n
      child public key  = P + h·G

  Keys are raw binaries: 32-byte private, 33-byte compressed public.
  Only BRC-77's anyone form is read; an envelope for a named recipient is
  refused, since checking it needs that recipient's private key.
  """

  alias Curvy.{Key, Point}

  @version <<0x42, 0x42, 0x33, 0x01>>
  @anyone <<0>>
  @invoice_prefix "2-message signing-"
  @n Curvy.Curve.secp256k1().n
  @g Curvy.Curve.secp256k1()[:G]

  @type envelope :: %{signer: <<_::264>>, key_id: <<_::256>>, der: binary()}

  @doc "The 33-byte compressed public key for a 32-byte private key."
  @spec public_key(<<_::256>>) :: <<_::264>>
  def public_key(<<_::256>> = privkey), do: privkey |> Key.from_privkey() |> Key.to_pubkey()

  @doc """
  Signs `message` (its exact bytes) with the identity key `privkey`, under the
  32-byte `key_id`, and returns the envelope as bytes.
  """
  @spec sign(binary(), <<_::256>>, <<_::256>>) :: binary()
  def sign(message, <<d::big-size(256)>> = privkey, <<_::256>> = key_id)
      when is_binary(message) do
    identity = public_key(privkey)
    child = rem(d + tweak(identity, key_id), @n)
    der = Curvy.sign(message, <<child::big-size(256)>>, hash: :sha256)
    IO.iodata_to_binary([@version, identity, @anyone, key_id, der])
  end

  @doc """
  Reads an envelope's parts.

  Returns `{:ok, %{signer, key_id, der}}`, `{:error, :not_anyone}` for an
  envelope addressed to one recipient, or `{:error, :malformed_envelope}`.
  """
  @spec parse(binary()) :: {:ok, envelope()} | {:error, :not_anyone | :malformed_envelope}
  def parse(<<@version, signer::binary-33, @anyone, key_id::binary-32, der::binary>>)
      when byte_size(der) > 0,
      do: {:ok, %{signer: signer, key_id: key_id, der: der}}

  def parse(<<@version, _signer::binary-33, _recipient::binary-33, _rest::binary>>),
    do: {:error, :not_anyone}

  def parse(_envelope), do: {:error, :malformed_envelope}

  @doc """
  Checks `envelope` over the exact `message` bytes.

  Returns `{:ok, signer}` with the identity key that signed, or
  `{:error, reason}`: `:malformed_envelope`, `:not_anyone`, or
  `:signature_fails` (which includes a signer key that isn't on the curve).
  Whether the signer is the one expected is the caller's check.
  """
  @spec verify(binary(), binary()) ::
          {:ok, <<_::264>>} | {:error, :malformed_envelope | :not_anyone | :signature_fails}
  def verify(message, envelope) when is_binary(message) and is_binary(envelope) do
    with {:ok, %{signer: signer, key_id: key_id, der: der}} <- parse(envelope) do
      if valid?(message, signer, key_id, der),
        do: {:ok, signer},
        else: {:error, :signature_fails}
    end
  end

  defp valid?(message, signer, key_id, der) do
    point = Key.from_pubkey(signer).point
    child = Point.add(point, Point.mul(@g, tweak(signer, key_id)))
    Curvy.verify(der, message, Key.from_point(child), hash: :sha256) == true
  rescue
    _ -> false
  end

  # The BRC-42 HMAC, as an integer: keyed by the shared secret with anyone,
  # which is the signer's own public key.
  defp tweak(<<_::264>> = identity, key_id) do
    invoice = @invoice_prefix <> Base.encode64(key_id)
    :crypto.mac(:hmac, :sha256, identity, invoice) |> :binary.decode_unsigned()
  end
end
