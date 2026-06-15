defmodule BitblocksWeb.Utils.BsvParams do
  @moduledoc """
  Validation for caller-supplied BSV identifiers before they reach a
  database query, an outbound proxy URL, or a PubSub topic.

  ## Why this exists

  Path/query params arrive across the hostile boundary TB1 (THREAT-MODEL.md).
  Several of them are interpolated into outbound WhatsOnChain proxy URLs
  (threat T7) or PubSub channel names (threat T8) without prior validation.
  An unvalidated identifier can alter the outbound request path or inject a
  separator into a topic string. Validating to a strict charset/length here —
  before interpolation — closes both, and is also a cheap guard against
  expensive lookups on absurd inputs.

  Every function returns `{:ok, value}` or `{:error, reason}`; callers decide
  the HTTP status. Validation does not mutate the value (a valid identifier is
  already URL-safe), but callers should still treat these as the *only* values
  allowed to reach a URL or topic.
  """

  # A txid / block hash is exactly 32 bytes, hex-encoded → 64 hex chars.
  @hash_re ~r/\A[0-9a-fA-F]{64}\z/

  # Base58 alphabet (no 0/O/I/l). BSV addresses are 26–35 chars; allow a little
  # slack for variants but keep it bounded.
  @address_re ~r/\A[1-9A-HJ-NP-Za-km-z]{26,40}\z/

  # Token ids in the order-book are `<txid>_<vout>` style identifiers. Restrict
  # to a safe charset so they can never inject a `:` into a PubSub topic or a
  # `/` into a URL path. Bounded length.
  @token_id_re ~r/\A[0-9a-fA-F]{1,64}(_[0-9]{1,10})?\z/

  @doc "Validate a transaction id or block hash (64 hex chars)."
  @spec txid(any()) :: {:ok, String.t()} | {:error, :invalid_txid}
  def txid(value) when is_binary(value) do
    if Regex.match?(@hash_re, value), do: {:ok, value}, else: {:error, :invalid_txid}
  end

  def txid(_), do: {:error, :invalid_txid}

  @doc "Validate a base58 BSV address."
  @spec address(any()) :: {:ok, String.t()} | {:error, :invalid_address}
  def address(value) when is_binary(value) do
    if Regex.match?(@address_re, value), do: {:ok, value}, else: {:error, :invalid_address}
  end

  def address(_), do: {:error, :invalid_address}

  @doc "Validate an order-book token id (safe for URL paths and PubSub topics)."
  @spec token_id(any()) :: {:ok, String.t()} | {:error, :invalid_token_id}
  def token_id(value) when is_binary(value) do
    if Regex.match?(@token_id_re, value), do: {:ok, value}, else: {:error, :invalid_token_id}
  end

  def token_id(_), do: {:error, :invalid_token_id}
end
