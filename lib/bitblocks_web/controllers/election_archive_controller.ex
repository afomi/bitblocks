defmodule BitblocksWeb.ElectionArchiveController do
  @moduledoc """
  `GET /elections/:outpoint/archive.zip`, admins only: "Download the archive
  (.zip)" on `/elections/:outpoint` (https://github.com/afomi/bitblocks/issues/136).

  Builds the archive again (`BitblocksWeb.ElectionArchive.zip/2`), which
  gives the same files for the same chain. `?sha256=` is the archive_sha256
  the page showed: when the archive built now hashes to something else (a
  reorg can do that), the answer is a 409 saying so, never a different zip.
  """
  use BitblocksWeb, :controller

  alias BitblocksWeb.ElectionArchive

  def download(conn, %{"outpoint" => outpoint} = params) do
    opts =
      case params["result_txid"] do
        txid when is_binary(txid) and txid != "" -> [result_txid: txid]
        _ -> []
      end

    expected = params["sha256"]

    case ElectionArchive.zip(outpoint, opts) do
      {:ok, %{archive_sha256: sha256} = zip} when expected in [nil, "", sha256] ->
        conn
        |> put_resp_header("x-archive-sha256", sha256)
        |> send_download({:binary, zip.bytes},
          filename: zip.name,
          content_type: "application/zip"
        )

      {:ok, %{archive_sha256: sha256}} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          409,
          "The archive now hashes to #{sha256}, not the #{expected} shown on the page. " <>
            "The chain may have changed under it; build it again on the election's page.\n"
        )

      {:error, sentence} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(409, sentence <> "\n")
    end
  end
end
