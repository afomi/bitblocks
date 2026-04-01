defmodule Bitblocks.VanityDID do
  @moduledoc """
  Generates DID key pairs where the corresponding Bitcoin address matches a vanity prefix.

  This allows creating DIDs with memorable Bitcoin addresses derived from the same key material.
  """

  @base58_alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  @doc """
  Validates that a prefix contains only valid Base58 characters.
  Returns :ok or {:error, invalid_chars}.
  """
  def validate_prefix(prefix) do
    valid_chars = String.graphemes(@base58_alphabet)

    invalid_chars =
      prefix
      |> String.graphemes()
      |> Enum.reject(&(&1 in valid_chars))

    if Enum.empty?(invalid_chars) do
      :ok
    else
      {:error, invalid_chars}
    end
  end

  @doc """
  Estimates the number of attempts needed to find a match.
  """
  def estimate_difficulty(prefix_length, case_sensitive \\ false) do
    # Each character in base58 has ~58 possibilities
    # Case-insensitive reduces this to ~29 for letters
    base = if case_sensitive, do: 58, else: 29
    trunc(:math.pow(base, prefix_length))
  end

  @doc """
  Searches for a keypair whose Bitcoin address matches the given prefix.
  Returns {:ok, result} or {:error, :timeout} after max_attempts.

  Options:
  - :case_sensitive - Match case (default: false)
  - :suffix - Match suffix instead of prefix (default: false)
  - :max_attempts - Stop after this many attempts (default: 10_000_000)
  - :progress_callback - Called with attempt count periodically
  """
  def search(prefix, opts \\ []) do
    case_sensitive = Keyword.get(opts, :case_sensitive, false)
    suffix = Keyword.get(opts, :suffix, false)
    max_attempts = Keyword.get(opts, :max_attempts, 10_000_000)
    progress_callback = Keyword.get(opts, :progress_callback)

    search_loop(prefix, case_sensitive, suffix, max_attempts, progress_callback, 0)
  end

  defp search_loop(_prefix, _case_sensitive, _suffix, max_attempts, _callback, attempts)
       when attempts >= max_attempts do
    {:error, :timeout, attempts}
  end

  defp search_loop(prefix, case_sensitive, suffix, max_attempts, callback, attempts) do
    # Report progress every 1000 attempts
    if callback && rem(attempts, 1000) == 0 && attempts > 0 do
      callback.(attempts)
    end

    # Generate random private key (32 bytes)
    private_key_bytes = :crypto.strong_rand_bytes(32)

    case generate_address(private_key_bytes) do
      {:ok, address, wif} ->
        if matches?(address, prefix, case_sensitive, suffix) do
          # Convert private key to JWK format for DID use
          {:ok, priv_key} = BSV.PrivKey.from_binary(private_key_bytes)
          pub_key = BSV.PubKey.from_privkey(priv_key)

          {:ok,
           %{
             address: address,
             wif: wif,
             private_key_hex: Base.encode16(private_key_bytes, case: :lower),
             pub_key: pub_key,
             priv_key: priv_key,
             attempts: attempts + 1
           }}
        else
          search_loop(prefix, case_sensitive, suffix, max_attempts, callback, attempts + 1)
        end

      {:error, _reason} ->
        search_loop(prefix, case_sensitive, suffix, max_attempts, callback, attempts + 1)
    end
  end

  defp matches?(address, prefix, case_sensitive, suffix) do
    search_string = if case_sensitive, do: prefix, else: String.downcase(prefix)

    # Skip the first character (always '1' for P2PKH addresses)
    address_part =
      address
      |> String.slice(1..-1//1)
      |> then(&if case_sensitive, do: &1, else: String.downcase(&1))

    if suffix do
      String.ends_with?(address_part, search_string)
    else
      String.starts_with?(address_part, search_string)
    end
  end

  defp generate_address(private_key_bytes) do
    try do
      {:ok, priv} = BSV.PrivKey.from_binary(private_key_bytes)
      pubkey = BSV.PubKey.from_privkey(priv)
      addr = BSV.Address.from_pubkey(pubkey)
      address_string = BSV.Address.to_string(addr)
      wif_string = BSV.PrivKey.to_wif(priv)
      {:ok, address_string, wif_string}
    rescue
      _ -> {:error, :generation_failed}
    end
  end

  @doc """
  Converts an EC public key to JWK format for use in DIDs.
  The BSV library uses secp256k1, so we create a JWK with that curve.
  """
  def pubkey_to_jwk(%BSV.PubKey{point: {x, y}}) do
    %{
      "kty" => "EC",
      "crv" => "secp256k1",
      "x" => base64url_encode(int_to_32_bytes(x)),
      "y" => base64url_encode(int_to_32_bytes(y))
    }
  end

  @doc """
  Converts an EC private key to JWK format (includes public key components).
  """
  def privkey_to_jwk(%BSV.PrivKey{d: d}, %BSV.PubKey{point: {x, y}}) do
    %{
      "kty" => "EC",
      "crv" => "secp256k1",
      "x" => base64url_encode(int_to_32_bytes(x)),
      "y" => base64url_encode(int_to_32_bytes(y)),
      "d" => base64url_encode(int_to_32_bytes(d))
    }
  end

  defp int_to_32_bytes(int) when is_integer(int) do
    <<int::unsigned-big-256>>
  end

  defp base64url_encode(bytes) do
    Base.url_encode64(bytes, padding: false)
  end

  @doc """
  Format large numbers for display.
  """
  def format_number(n) when n < 1_000, do: to_string(n)
  def format_number(n) when n < 1_000_000, do: "#{Float.round(n / 1_000, 1)}K"
  def format_number(n) when n < 1_000_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def format_number(n), do: "#{Float.round(n / 1_000_000_000, 1)}B"
end
