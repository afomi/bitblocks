defmodule Bitblocks.Interop.Brc77 do
  @moduledoc """
  BRC-77 signed messages: for anyone to check, or for one named recipient.

  An envelope is

      42423301 | signer identity key (33) | recipient | keyID (32) | DER signature

  where `recipient` is `00` for anyone, or the recipient's 33-byte identity key.
  The signature is ECDSA over SHA-256 of the exact message bytes, deterministic
  (RFC 6979) and low-S, by the signer's BRC-42 child key
  (`Bitblocks.Interop.Brc42`) for the BRC-43 invoice
  `"2-message signing-<base64 keyID>"` with the recipient as counterparty.
  That is what `@bsv/sdk`'s `SignedMessage.sign`, and a BRC-100 wallet's
  `createSignature` with protocol `[2, "message signing"]`, make.

  ## Who can check it

    * Anyone: "anyone" is the key whose private scalar is 1, so its public key
      is `G` and the secret it shares with the signer is the signer's own public
      key. `verify/2` needs nothing but the message and the envelope.
    * A named recipient: the secret is ECDH between the signer and the
      recipient, so only the recipient's private key checks it (`verify/3`).
      To everyone else the envelope says nothing about whether it's valid.

  Keys are raw binaries: 32-byte private, 33-byte compressed public.

  Pinned to `@bsv/sdk`'s `SignedMessage` tests, BRC-42's vectors and the
  BRC-3 compliance vector (`test/bitblocks/interop/brc42_test.exs`,
  `test/bitblocks/interop/brc77_test.exs`), and to qart's envelopes byte for
  byte (`test/bitblocks/interop/receipt_v2_vectors_test.exs`).
  """

  alias Bitblocks.Interop.Brc42
  alias Curvy.Key

  @version <<0x42, 0x42, 0x33, 0x01>>
  @anyone <<0>>
  @invoice_prefix "2-message signing-"

  @type envelope :: %{
          signer: <<_::264>>,
          recipient: :anyone | <<_::264>>,
          key_id: <<_::256>>,
          der: binary()
        }

  @doc "The 33-byte compressed public key for a 32-byte private key."
  @spec public_key(<<_::256>>) :: <<_::264>>
  def public_key(<<_::256>> = privkey), do: Brc42.public_key(privkey)

  @doc "A fresh random 32-byte key ID, as BRC-77 asks of each signature."
  @spec key_id() :: <<_::256>>
  def key_id, do: :crypto.strong_rand_bytes(32)

  @doc """
  Signs `message` (its exact bytes) with the identity key `privkey`, under the
  32-byte `key_id`, for `recipient` (`:anyone`, the default, or a 33-byte
  compressed public key), and returns the envelope as bytes.

  Raises `ArgumentError` for a signing key out of range, or a recipient that
  isn't a point on the curve.
  """
  @spec sign(binary(), <<_::256>>, <<_::256>>, :anyone | <<_::264>>) :: binary()
  def sign(message, privkey, key_id, recipient \\ :anyone)

  def sign(message, <<_::256>> = privkey, <<_::256>> = key_id, recipient)
      when is_binary(message) do
    unless Brc42.valid_private?(privkey),
      do: raise(ArgumentError, "the signing key must be a scalar from 1 to n - 1")

    counterparty = if recipient == :anyone, do: Brc42.anyone_public(), else: recipient

    case Brc42.private_child(privkey, counterparty, invoice(key_id)) do
      {:ok, child} ->
        der = Curvy.sign(message, child, hash: :sha256)
        recipient_bytes = if recipient == :anyone, do: @anyone, else: recipient
        IO.iodata_to_binary([@version, public_key(privkey), recipient_bytes, key_id, der])

      :error ->
        raise ArgumentError, "the recipient must be a compressed public key on secp256k1"
    end
  end

  @doc """
  Reads an envelope's parts: `{:ok, %{signer, recipient, key_id, der}}`, with
  `recipient` `:anyone` or a 33-byte key, or `{:error, :malformed_envelope}`.
  """
  @spec parse(binary()) :: {:ok, envelope()} | {:error, :malformed_envelope}
  def parse(<<@version, signer::binary-33, @anyone, key_id::binary-32, der::binary>>)
      when byte_size(der) > 0,
      do: {:ok, %{signer: signer, recipient: :anyone, key_id: key_id, der: der}}

  def parse(
        <<@version, signer::binary-33, prefix, recipient::binary-32, key_id::binary-32,
          der::binary>>
      )
      when prefix in [2, 3] and byte_size(der) > 0,
      do:
        {:ok,
         %{signer: signer, recipient: <<prefix, recipient::binary>>, key_id: key_id, der: der}}

  def parse(_envelope), do: {:error, :malformed_envelope}

  @doc """
  Checks an envelope for anyone over the exact `message` bytes.

  Returns `{:ok, signer}` with the identity key that signed, or
  `{:error, reason}`: `:malformed_envelope`, `:not_anyone` (an envelope for a
  named recipient, which only `verify/3` with that recipient's key can check),
  or `:signature_fails` (which includes a signer key that isn't on the curve).
  Whether the signer is the one expected is the caller's check.
  """
  @spec verify(binary(), binary()) ::
          {:ok, <<_::264>>} | {:error, :malformed_envelope | :not_anyone | :signature_fails}
  def verify(message, envelope) when is_binary(message) and is_binary(envelope) do
    case parse(envelope) do
      {:ok, %{recipient: :anyone} = parts} -> check(message, parts, Brc42.anyone_private())
      {:ok, _parts} -> {:error, :not_anyone}
      error -> error
    end
  end

  @doc """
  Checks an envelope addressed to the holder of `recipient_privkey`, or one
  for anyone (which any key may check, as `@bsv/sdk` does).

  Returns `{:ok, signer}`, or `{:error, reason}`: `:malformed_envelope`,
  `:wrong_recipient` (addressed to another key), or `:signature_fails`.
  """
  @spec verify(binary(), binary(), <<_::256>>) ::
          {:ok, <<_::264>>}
          | {:error, :malformed_envelope | :wrong_recipient | :signature_fails}
  def verify(message, envelope, <<_::256>> = recipient_privkey)
      when is_binary(message) and is_binary(envelope) do
    with {:ok, parts} <- parse(envelope) do
      cond do
        parts.recipient == :anyone ->
          check(message, parts, Brc42.anyone_private())

        not Brc42.valid_private?(recipient_privkey) or
            parts.recipient != public_key(recipient_privkey) ->
          {:error, :wrong_recipient}

        true ->
          check(message, parts, recipient_privkey)
      end
    end
  end

  # The signer's child public key, as the recipient computes it, against the DER.
  defp check(message, %{signer: signer, key_id: key_id, der: der}, recipient_privkey) do
    with {:ok, child} <- Brc42.public_child(recipient_privkey, signer, invoice(key_id)),
         true <- Curvy.verify(der, message, Key.from_pubkey(child), hash: :sha256) == true do
      {:ok, signer}
    else
      _ -> {:error, :signature_fails}
    end
  rescue
    _ -> {:error, :signature_fails}
  end

  defp invoice(key_id), do: @invoice_prefix <> Base.encode64(key_id)
end
