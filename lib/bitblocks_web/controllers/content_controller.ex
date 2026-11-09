defmodule BitblocksWeb.ContentController do
  @moduledoc """
  `GET /content/:outpoint`: an inscription's body, parsed out of the raw tx on
  the fly (1Sat's `/content/{txid}_{vout}` convention; `.` or `:` also work,
  and a bare txid means output 0). Nothing is pre-extracted: the tx's bytes
  are the source of truth and the parse is cheap.

  `GET /b/:txid`: a B:// file, read the same way (`Bitblocks.Bitcom.BFile`),
  with the same headers. It is the endpoint a `$ route add` can name for B://.

  Bytes come from `Bitblocks.TxStore.raw/1` (database, then blob store). A tx
  we hold nowhere is fetched from WhatsOnChain, checked against its txid, and
  kept in the blob store only, so public requests can't fill the database.

  Inscriptions are untrusted (SVG can carry script), so responses are
  `nosniff` with a sandboxing CSP, and immutable.

  `GET /content/bcat/:txid` serves the file a BCat head names, its chunks
  joined in order (`Bitblocks.Bcat`), under the same headers; `?download=1`
  asks for a download. A file with any chunk short is an error that names the
  chunks, never a partial body.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Bitcom.BFile
  alias Bitblocks.Chain.RawTx
  alias Bitblocks.Ordinals.Inscription
  alias Bitblocks.{Bcat, TxStore}

  @csp "sandbox; default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; font-src 'self' data:"

  def show(conn, %{"outpoint" => raw_outpoint}) do
    with {:ok, txid, vout} <- parse(raw_outpoint),
         {:ok, bytes} <- bytes(txid),
         {:ok, tx} <- RawTx.parse(Base.encode16(bytes)),
         %BSV.TxOut{script: script} <- Enum.at(tx.outputs, vout) || {:error, :no_output},
         {:ok, %{content: content} = insc} when is_binary(content) <- Inscription.parse(script) do
      serve(conn, insc.content_type, content)
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

  def b(conn, %{"txid" => raw_txid}) do
    with {:ok, txid} <- parse_txid(raw_txid),
         {:ok, bytes} <- bytes(txid),
         {:ok, tx} <- RawTx.parse(Base.encode16(bytes)),
         {:ok, file} <- BFile.parse(tx) do
      serve(conn, file.media_type, file.content)
    else
      {:error, :bad_txid} ->
        error(conn, 400, "Expected /b/<txid>")

      {:error, :not_found} ->
        error(conn, 404, "unknown transaction")

      {:error, {:fetch_failed, _}} ->
        error(conn, 502, "could not fetch the transaction; try again")

      _ ->
        error(conn, 404, "no B:// file in this transaction")
    end
  end

  defp serve(conn, type, content) do
    conn
    |> put_resp_content_type(content_type(type), nil)
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", @csp)
    |> send_resp(200, content)
  end

  defp parse_txid(raw) do
    txid = String.downcase(raw)
    if txid =~ ~r/\A[0-9a-f]{64}\z/, do: {:ok, txid}, else: {:error, :bad_txid}
  end

  def bcat(conn, %{"txid" => raw} = params) do
    txid = String.downcase(raw)

    with true <- txid =~ ~r/\A[0-9a-f]{64}\z/ || {:error, :bad_txid},
         {:ok, file} <- Bcat.assemble(txid) do
      conn
      |> put_resp_content_type(bcat_type(file), nil)
      |> put_resp_header("content-disposition", disposition(file, params["download"]))
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", @csp)
      |> send_resp(200, file.data)
    else
      {:error, :bad_txid} ->
        error(conn, 400, "Expected /content/bcat/<64 hex txid>")

      {:error, :not_found} ->
        error(conn, 404, "unknown transaction")

      {:error, :not_bcat} ->
        error(conn, 404, "this transaction is not a BCat head")

      {:error, :no_chunks} ->
        error(conn, 404, "this BCat head names no chunks")

      {:error, :too_large} ->
        error(conn, 413, "this BCat file is larger than this endpoint serves")

      {:error, {:missing, txids}} ->
        chunks_error(conn, 404, "chunks are missing, so the file was not assembled", txids)

      {:error, {:unavailable, txids}} ->
        chunks_error(conn, 502, "chunks could not be fetched; try again", txids)

      {:error, {:fetch_failed, _}} ->
        error(conn, 502, "could not fetch the transaction from upstream; try again")
    end
  end

  defp chunks_error(conn, status, message, txids) do
    conn |> put_status(status) |> json(%{error: message, missing_chunks: txids})
  end

  defp bcat_type(%{mime: mime, charset: charset}) when is_binary(charset) do
    content_type(if mime, do: "#{mime}; charset=#{charset}")
  end

  defp bcat_type(%{mime: mime}), do: content_type(mime)

  # The name is chain data: only plain filename characters reach the header.
  defp disposition(file, download) do
    kind = if download in ["1", "true"], do: "attachment", else: "inline"

    case file.filename && String.replace(file.filename, ~r/[^A-Za-z0-9._-]/, "_") do
      name when is_binary(name) and name != "" -> ~s(#{kind}; filename="#{name}")
      _ -> kind
    end
  end

  defp parse(raw) do
    case Regex.run(~r/\A([0-9a-f]{64})(?:[_.:](\d+))?\z/, String.downcase(raw)) do
      [_, txid] -> {:ok, txid, 0}
      [_, txid, vout] -> {:ok, txid, String.to_integer(vout)}
      _ -> {:error, :bad_outpoint}
    end
  end

  defp bytes(txid), do: TxStore.raw_or_fetch(txid)

  # Only a plain type/subtype (plus parameters) is echoed back.
  defp content_type(type) when is_binary(type) do
    if type =~ ~r/\A[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*(;[ -~]*)?\z/i,
      do: type,
      else: "application/octet-stream"
  end

  defp content_type(_), do: "application/octet-stream"

  defp error(conn, status, message), do: conn |> put_status(status) |> json(%{error: message})
end
