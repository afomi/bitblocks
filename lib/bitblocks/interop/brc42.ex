defmodule Bitblocks.Interop.Brc42 do
  @moduledoc """
  BRC-42 key derivation: a child key two parties can each compute for one
  invoice number, one from its private key and the other's public key.

      secret            = a·B = b·A           (ECDH, the compressed point)
      h                 = HMAC-SHA256(key: compressed(secret), data: invoice)
      child private key = b + h mod n         (the recipient's, `private_child/3`)
      child public key  = B + h·G             (anyone holding a, `public_child/3`)

  "Anyone" is the key whose private scalar is 1 (`anyone_private/0`), so its
  public key is `G` and its shared secret with any key is that key itself.

  Keys are raw binaries: 32-byte private, 33-byte compressed public. A public
  key that isn't a point on the curve is `:error`.

  Pinned to BRC-42's own test vectors and to `@bsv/sdk`'s BRC-3 compliance
  vector (`test/bitblocks/interop/brc42_test.exs`).
  """

  alias Curvy.{Key, Point}

  @n Curvy.Curve.secp256k1().n
  @g Curvy.Curve.secp256k1()[:G]

  @doc "The private key of anyone: the scalar 1."
  @spec anyone_private() :: <<_::256>>
  def anyone_private, do: <<1::big-size(256)>>

  @doc "The public key of anyone: `G`, compressed."
  @spec anyone_public() :: <<_::264>>
  def anyone_public, do: public_key(anyone_private())

  @doc "Whether 32 bytes are a private key: a scalar from 1 to n - 1."
  @spec valid_private?(binary()) :: boolean()
  def valid_private?(<<d::big-size(256)>>), do: d > 0 and d < @n
  def valid_private?(_), do: false

  @doc """
  A configured private key as 32 bytes: 64 hex digits, or a WIF (compressed
  or not, mainnet `0x80` or testnet `0xef`; the key is the same 32 bytes
  either way), surrounding whitespace ignored. `:invalid` for anything else,
  or a scalar out of range. Never raises, and never puts the value in an error.
  """
  @spec decode_private(String.t()) :: {:ok, <<_::256>>} | :invalid
  def decode_private(value) when is_binary(value) do
    case String.trim(value) do
      <<_::binary-64>> = hex ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, privkey} -> in_range(privkey)
          :error -> decode_wif(hex)
        end

      other ->
        decode_wif(other)
    end
  end

  defp decode_wif(value) do
    case B58.decode58_check(value) do
      {:ok, {<<privkey::binary-32, 1>>, version}} when version in [<<0x80>>, <<0xEF>>] ->
        in_range(privkey)

      {:ok, {<<privkey::binary-32>>, version}} when version in [<<0x80>>, <<0xEF>>] ->
        in_range(privkey)

      _ ->
        :invalid
    end
  rescue
    _ -> :invalid
  end

  defp in_range(privkey), do: if(valid_private?(privkey), do: {:ok, privkey}, else: :invalid)

  @doc "Whether 33 bytes are a compressed public key on the curve."
  @spec valid_public?(binary()) :: boolean()
  def valid_public?(pubkey) when is_binary(pubkey), do: match?({:ok, _}, point(pubkey))
  def valid_public?(_), do: false

  @doc "The 33-byte compressed public key for a 32-byte private key."
  @spec public_key(<<_::256>>) :: <<_::264>>
  def public_key(<<_::256>> = privkey), do: privkey |> Key.from_privkey() |> Key.to_pubkey()

  @doc """
  The compressed shared secret of `privkey` and `pubkey`: `privkey · pubkey`.
  `:error` when `pubkey` isn't a point on the curve.
  """
  @spec shared_secret(<<_::256>>, binary()) :: {:ok, <<_::264>>} | :error
  def shared_secret(<<d::big-size(256)>> = privkey, pubkey) when is_binary(pubkey) do
    with true <- valid_private?(privkey) || :error,
         {:ok, point} <- point(pubkey) do
      {:ok, point |> Point.mul(d) |> Key.from_point() |> Key.to_pubkey()}
    end
  end

  @doc """
  The recipient's child private key: `privkey + h mod n`, where `h` is the
  HMAC of `invoice` under the secret shared with `counterparty` (a public key).
  """
  @spec private_child(<<_::256>>, binary(), String.t()) :: {:ok, <<_::256>>} | :error
  def private_child(<<d::big-size(256)>> = privkey, counterparty, invoice)
      when is_binary(invoice) do
    with {:ok, secret} <- shared_secret(privkey, counterparty) do
      {:ok, <<rem(d + hmac(secret, invoice), @n)::big-size(256)>>}
    end
  end

  @doc """
  The child public key of `pubkey` that its holder's `private_child/3` gives,
  computed by `privkey`'s holder: `pubkey + h·G`.
  """
  @spec public_child(<<_::256>>, binary(), String.t()) :: {:ok, <<_::264>>} | :error
  def public_child(<<_::256>> = privkey, pubkey, invoice) when is_binary(invoice) do
    with {:ok, secret} <- shared_secret(privkey, pubkey),
         {:ok, point} <- point(pubkey) do
      child = Point.add(point, Point.mul(@g, hmac(secret, invoice)))

      if Point.valid?(child),
        do: {:ok, child |> Key.from_point() |> Key.to_pubkey()},
        else: :error
    end
  end

  defp hmac(secret, invoice),
    do: :crypto.mac(:hmac, :sha256, secret, invoice) |> :binary.decode_unsigned()

  # Compressed only, and on the curve (`Key.parse_pubkey/1` checks both).
  defp point(<<prefix, _::binary-32>> = pubkey) when prefix in [2, 3] do
    case Key.parse_pubkey(pubkey) do
      {:ok, %Key{point: point}} -> {:ok, point}
      :error -> :error
    end
  end

  defp point(_pubkey), do: :error
end
