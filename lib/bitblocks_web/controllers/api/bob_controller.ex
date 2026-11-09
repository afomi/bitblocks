defmodule BitblocksWeb.Api.BobController do
  @moduledoc """
  `GET /api/v1/txs/:txid/bob`: a transaction as BOB, unwriter's tape-and-cell
  shape (`Bitblocks.Bob`), read from its bytes on the fly, so code written
  against BOB can read any tx we can find.

    * 400: not a txid;
    * 404: no one has the tx;
    * 413: the tx is larger than this endpoint shapes;
    * 502: WhatsOnChain couldn't be read for a tx we don't hold.

  A confirmed tx's BOB never changes, but `blk` appears once the sync stores
  its block, so answers are cached briefly rather than forever.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Bob

  @doc "GET /api/v1/txs/:txid/bob"
  def show(conn, %{"txid" => txid}) do
    txid = String.downcase(txid)

    with true <- txid =~ ~r/\A[0-9a-f]{64}\z/ || {:error, :bad_txid},
         {:ok, bob} <- Bob.for_txid(txid) do
      conn
      |> put_resp_header("cache-control", "public, max-age=300")
      |> json(%{data: bob})
    else
      {:error, :bad_txid} ->
        error(conn, 400, "Expected /api/v1/txs/<64 hex txid>/bob")

      {:error, :not_found} ->
        error(conn, 404, "unknown transaction")

      {:error, :too_large} ->
        error(
          conn,
          413,
          "this transaction is over #{Bob.max_bytes()} bytes; read its raw bytes instead"
        )

      {:error, {:fetch_failed, _}} ->
        error(conn, 502, "could not fetch the transaction; try again")

      {:error, :invalid_tx} ->
        error(conn, 500, "the bytes held for this transaction did not parse")
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{error: message})
  end
end
