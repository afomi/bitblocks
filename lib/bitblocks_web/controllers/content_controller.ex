defmodule BitblocksWeb.ContentController do
  @moduledoc """
  `GET /content/:outpoint`: an inscription's body, parsed out of the raw tx on
  the fly (1Sat's `/content/{txid}_{vout}` convention; `.` or `:` also work,
  and a bare txid means output 0). Nothing is pre-extracted: the tx's bytes
  are the source of truth and the parse is cheap.

  Bytes come from `Bitblocks.TxStore.raw/1` (database, then blob store). A tx
  we hold nowhere is fetched from WhatsOnChain, checked against its txid, and
  kept in the blob store only, so public requests can't fill the database.

  Inscriptions are untrusted (SVG can carry script), so responses are
  `nosniff` with a sandboxing CSP, and immutable.
  """
  use BitblocksWeb, :controller

  require Logger

  alias Bitblocks.Chain.RawTx
  alias Bitblocks.Ordinals.Inscription
  alias Bitblocks.{TxStore, Woc}

  @csp "sandbox; default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; font-src 'self' data:"

  def show(conn, %{"outpoint" => raw_outpoint}) do
    with {:ok, txid, vout} <- parse(raw_outpoint),
         {:ok, bytes} <- bytes(txid),
         {:ok, tx} <- RawTx.parse(Base.encode16(bytes)),
         %BSV.TxOut{script: script} <- Enum.at(tx.outputs, vout) || {:error, :no_output},
         {:ok, %{content: content} = insc} when is_binary(content) <- Inscription.parse(script) do
      conn
      |> put_resp_content_type(content_type(insc.content_type), nil)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", @csp)
      |> send_resp(200, content)
    else
      {:error, :bad_outpoint} ->
        error(conn, 400, "Expected /content/<txid>_<vout>")

      {:error, :not_found} ->
        error(conn, 404, "unknown transaction")

      {:error, :no_output} ->
        error(conn, 404, "no such output")

      {:error, {:fetch_failed, _}} ->
        error(conn, 502, "could not fetch the transaction from upstream; try again")

      _ ->
        error(
          conn,
          404,
          "no inscription at this outpoint (encrypted or non-1Sat content isn't served)"
        )
    end
  end

  defp parse(raw) do
    case Regex.run(~r/\A([0-9a-f]{64})(?:[_.:](\d+))?\z/, String.downcase(raw)) do
      [_, txid] -> {:ok, txid, 0}
      [_, txid, vout] -> {:ok, txid, String.to_integer(vout)}
      _ -> {:error, :bad_outpoint}
    end
  end

  # Ours if we hold it (database or blob store); otherwise fetched. An
  # unreadable blob store (e.g. no bucket yet) is a miss, not an error.
  defp bytes(txid) do
    case TxStore.raw(txid) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> fetch(txid)
    end
  end

  # Fetched bytes are served only if they hash to the txid. Caching them in
  # the blob store is best-effort: a failed write is logged, not fatal.
  defp fetch(txid) do
    with {:ok, [%{"hex" => hex} | _]} <- Woc.txs([txid]),
         {:ok, bytes} <- Base.decode16(hex, case: :mixed),
         ^txid <- TxStore.txid(bytes) do
      case TxStore.put(txid, bytes) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("content: not cached #{txid}: #{inspect(reason)}")
      end

      {:ok, bytes}
    else
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, {:fetch_failed, reason}}
      _ -> {:error, :not_found}
    end
  end

  # Only a plain type/subtype (plus parameters) is echoed back.
  defp content_type(type) when is_binary(type) do
    if type =~ ~r/\A[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*(;[ -~]*)?\z/i,
      do: type,
      else: "application/octet-stream"
  end

  defp content_type(_), do: "application/octet-stream"

  defp error(conn, status, message), do: conn |> put_status(status) |> json(%{error: message})
end
