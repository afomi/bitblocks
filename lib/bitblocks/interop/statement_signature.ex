defmodule Bitblocks.Interop.StatementSignature do
  @moduledoc """
  BRC-77 signatures over BRC-237 payment evidence statements (#64): the
  server signs the exact canonical bytes it made, so a statement can travel
  and anyone can tell it came from us.

  ## The key

  `STATEMENT_SIGNING_KEY`, read by `config/runtime.exs` into
  `:statement_signing_key`: a private key as 64 hex digits or as WIF. Unset,
  nothing is signed and a made statement says `signature: null`. It is never
  logged or shown; only `status/0` (`:configured`, `:not_configured` or
  `:invalid`) and the public identity key that signs leave this module.

  ## A signature

      %{
        scheme: "BRC-77",
        envelope: "<hex>",      # 42423301 | signer | recipient | keyID | DER
        signer: "<hex>",        # our identity key, compressed
        recipient: "anyone"     # or the verifier identity key it was made for
      }

  Each signature takes a fresh random key ID, as BRC-77 asks, so two
  signatures over the same bytes differ. The envelope signs the statement's
  exact bytes (`canonical`), never a re-serialization of them.

  ## Checking one

  `verify/3` in Elixir, or `@bsv/sdk` anywhere:

      import { SignedMessage, Utils } from '@bsv/sdk'
      SignedMessage.verify(Utils.toArray(canonical, 'utf8'),
                           Utils.toArray(envelope, 'hex'))   // true

  then compare the envelope's signer with the key you expect from us.
  A signature made for a named verifier checks only with that verifier's
  private key (`verify/3` with `:recipient_key`, or the SDK's third argument).
  """

  require Logger

  alias Bitblocks.Interop.{Brc42, Brc77}

  @scheme "BRC-77"

  @type signature :: %{
          scheme: String.t(),
          envelope: String.t(),
          signer: String.t(),
          recipient: String.t()
        }

  @doc """
  Whether a signing key is set and reads as one: `:configured`,
  `:not_configured`, or `:invalid` (set, but neither 64 hex digits nor a
  mainnet WIF for a scalar in range).
  """
  @spec status() :: :configured | :not_configured | :invalid
  def status do
    case key() do
      {:ok, _} -> :configured
      :none -> :not_configured
      :invalid -> :invalid
    end
  end

  @doc "True when statements will be signed."
  @spec configured?() :: boolean()
  def configured?, do: status() == :configured

  @doc """
  Signs `canonical` for `recipient` (`:anyone`, the default, or a 33-byte
  compressed identity key). `nil` when no key is set, and when the key set
  doesn't read as one (logged once, without the value).
  """
  @spec sign(binary(), :anyone | <<_::264>>) :: signature() | nil
  def sign(canonical, recipient \\ :anyone) when is_binary(canonical) do
    case key() do
      {:ok, privkey} ->
        envelope = Brc77.sign(canonical, privkey, Brc77.key_id(), recipient)

        %{
          scheme: @scheme,
          envelope: hex(envelope),
          signer: hex(Brc77.public_key(privkey)),
          recipient: if(recipient == :anyone, do: "anyone", else: hex(recipient))
        }

      :none ->
        nil

      :invalid ->
        warn_invalid_once()
        nil
    end
  end

  @doc """
  Reads a verifier identity key from a caller: 66 hex digits, a compressed
  key on the curve. `{:ok, :anyone}` for nil or `""`.
  """
  @spec parse_recipient(String.t() | nil) :: {:ok, :anyone | <<_::264>>} | :error
  def parse_recipient(nil), do: {:ok, :anyone}
  def parse_recipient(""), do: {:ok, :anyone}

  def parse_recipient(hex) when is_binary(hex) and byte_size(hex) == 66 do
    with {:ok, key} <- Base.decode16(hex, case: :mixed),
         {:ok, _secret} <- Brc42.shared_secret(Brc42.anyone_private(), key) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  def parse_recipient(_), do: :error

  @doc """
  Checks a signature over a statement's exact bytes.

  `envelope` is the envelope as hex or as bytes. Options:

    * `:signer`: the identity key (hex) you expect; another signer is
      `{:error, {:signer_mismatch, signer_hex}}`.
    * `:recipient_key`: your 32-byte private key, for a signature made for
      you as a named verifier.

  Returns `{:ok, %{signer: hex, recipient: "anyone" | hex}}`, or
  `{:error, reason}`: `:malformed_envelope`, `:not_anyone` (made for a named
  verifier, and no `:recipient_key` given), `:wrong_recipient`,
  `:signature_fails`, or the signer mismatch.
  """
  @spec verify(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(canonical, envelope, opts \\ []) when is_binary(canonical) and is_binary(envelope) do
    bytes = envelope_bytes(envelope)

    result =
      case opts[:recipient_key] do
        nil -> Brc77.verify(canonical, bytes)
        key -> Brc77.verify(canonical, bytes, key)
      end

    with {:ok, signer} <- result,
         {:ok, %{recipient: recipient}} <- Brc77.parse(bytes),
         :ok <- expected_signer(signer, opts[:signer]) do
      {:ok,
       %{
         signer: hex(signer),
         recipient: if(recipient == :anyone, do: "anyone", else: hex(recipient))
       }}
    end
  end

  defp envelope_bytes(envelope) do
    case Base.decode16(envelope, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> envelope
    end
  end

  defp expected_signer(_signer, nil), do: :ok

  defp expected_signer(signer, expected) do
    if hex(signer) == String.downcase(expected),
      do: :ok,
      else: {:error, {:signer_mismatch, hex(signer)}}
  end

  # The configured key as 32 bytes, read each time so a change to the
  # environment needs no recompile. The value never reaches a log.
  defp key do
    case Application.get_env(:bitblocks, :statement_signing_key) do
      nil -> :none
      "" -> :none
      value when is_binary(value) -> Brc42.decode_private(value)
      _ -> :invalid
    end
  end

  defp warn_invalid_once do
    unless :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.error(
        "STATEMENT_SIGNING_KEY is set but isn't a private key (64 hex digits or WIF); " <>
          "statements go out unsigned"
      )
    end
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
