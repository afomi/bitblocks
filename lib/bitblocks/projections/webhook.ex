defmodule Bitblocks.Projections.Webhook do
  @moduledoc """
  Webhook payloads and signatures for managed projections (#29 step 4).

  Each POST carries:

    * `x-bitblocks-event` — `tx` or `reorg`.
    * `x-bitblocks-signature` — `t=<unix seconds>,v1=<hex>`, where `v1` is
      HMAC-SHA256 of `"<t>.<body>"` keyed by the projection's webhook secret.
      Tenants recompute it (see `verify/4`) and reject stale timestamps, so a
      captured delivery can't be replayed later.

  Events:

    * `tx` — a matching tx confirmed in a block that just completed at the tip.
    * `reorg` — blocks above `rewind_height` were orphaned: drop rows above it.
      Matches on the new chain arrive as `tx` events as its blocks complete.

  Delivery is at least once (Oban retries); dedupe on `{txid, block_hash}`.
  """

  alias Bitblocks.Projections.Projection

  @doc "The JSON body for an event."
  @spec body(Projection.t(), map()) :: String.t()
  def body(%Projection{} = p, %{"event" => "tx"} = args) do
    Jason.encode!(%{
      event: "tx",
      projection_id: p.id,
      definition_hash: p.definition_hash,
      txid: args["txid"],
      block_height: args["block_height"],
      block_hash: args["block_hash"],
      proof_url: "/api/v1/txs/#{args["txid"]}/proof"
    })
  end

  def body(%Projection{} = p, %{"event" => "reorg"} = args) do
    Jason.encode!(%{
      event: "reorg",
      projection_id: p.id,
      definition_hash: p.definition_hash,
      rewind_height: args["rewind_height"]
    })
  end

  @doc "Headers for a body, signed at `timestamp` (unix seconds)."
  @spec headers(String.t(), String.t(), String.t(), integer()) :: [{String.t(), String.t()}]
  def headers(event, body, secret, timestamp \\ System.os_time(:second)) do
    [
      {"content-type", "application/json"},
      {"user-agent", "bitblocks-projections/1"},
      {"x-bitblocks-event", event},
      {"x-bitblocks-signature", "t=#{timestamp},v1=#{hmac(secret, "#{timestamp}.#{body}")}"}
    ]
  end

  @doc """
  True when `signature` (the header value) signs `body` with `secret` and its
  timestamp is within `tolerance` seconds of now (default 300).
  """
  @spec verify(String.t(), String.t() | nil, String.t(), non_neg_integer()) :: boolean()
  def verify(body, signature, secret, tolerance \\ 300)

  def verify(body, "t=" <> rest, secret, tolerance) do
    with [t, "v1=" <> mac] <- String.split(rest, ",", parts: 2),
         {timestamp, ""} <- Integer.parse(t),
         true <- abs(System.os_time(:second) - timestamp) <= tolerance do
      Plug.Crypto.secure_compare(mac, hmac(secret, "#{timestamp}.#{body}"))
    else
      _ -> false
    end
  end

  def verify(_body, _signature, _secret, _tolerance), do: false

  defp hmac(secret, data),
    do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)

  @doc """
  Default HTTP client: `{:ok, status}` or `{:error, reason}`. Swapped in tests
  via `config :bitblocks, :projection_webhook_client`.
  """
  @spec post(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, integer()} | {:error, term()}
  def post(url, body, headers) do
    case HTTPoison.post(url, body, headers, timeout: 5_000, recv_timeout: 10_000) do
      {:ok, %HTTPoison.Response{status_code: status}} -> {:ok, status}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, reason}
    end
  end
end
