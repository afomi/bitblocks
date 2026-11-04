defmodule BitblocksWeb.Api.RawTxController do
  @moduledoc """
  `GET /api/v1/txs/:txid/raw`: a transaction's exact bytes,
  `application/octet-stream`. The origin a CDN sits in front of
  (docs/TX_STORAGE.md, step 2).

  The bytes come from `Bitblocks.TxStore.raw/1`: the database's copy, the
  tx's own object, or a ranged read of its block's object. Every response's
  bytes are hashed here and must equal the txid; only then is the answer a
  200 with `cache-control: public, max-age=31536000, immutable`, since a
  confirmed tx's bytes never change. Errors are `no-store`, so a tx we don't
  hold yet isn't cached as missing.

    * 400: not a txid;
    * 404: we hold the tx nowhere;
    * 500: the bytes we hold don't hash to the txid (never served);
    * 503: the store couldn't be read; try again.

  Public, like the other tx reads; counted by the endpoint's rate limiter.
  Served outside the `:api` pipeline so a client asking for
  `application/octet-stream` isn't refused as not accepting JSON.
  """
  use BitblocksWeb, :controller

  require Logger

  alias Bitblocks.TxStore

  @immutable "public, max-age=31536000, immutable"

  @doc "GET /api/v1/txs/:txid/raw"
  def show(conn, %{"txid" => txid}) do
    txid = String.downcase(txid)

    with true <- txid =~ ~r/\A[0-9a-f]{64}\z/ || {:error, :bad_txid},
         {:ok, bytes} <- TxStore.raw(txid),
         ^txid <- TxStore.txid(bytes) do
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> put_resp_header("cache-control", @immutable)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, bytes)
    else
      {:error, :bad_txid} ->
        error(conn, 400, "Expected /api/v1/txs/<64 hex txid>/raw")

      {:error, :not_found} ->
        error(conn, 404, "unknown transaction")

      {:error, reason} when reason in [:invalid_hex, :bytes_do_not_hash_to_txid] ->
        mismatch(conn, txid, reason)

      # The database's bytes hash to another txid.
      other when is_binary(other) ->
        mismatch(conn, txid, {:hashes_to, other})

      {:error, reason} ->
        Logger.warning("raw tx #{txid}: store unreadable: #{inspect(reason)}")
        error(conn, 503, "the transaction store could not be read; try again")
    end
  end

  defp mismatch(conn, txid, reason) do
    Logger.error("raw tx #{txid}: held bytes refused: #{inspect(reason)}")
    error(conn, 500, "the bytes held for this transaction do not hash to its txid")
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_status(status)
    |> json(%{error: message})
  end
end
