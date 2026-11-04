defmodule BitblocksWeb.BlockImportController do
  @moduledoc """
  `POST /admin/blocks/:height`: imports one raw block pushed as
  `application/octet-stream` (an exported `<height>-<hash>.bin`, see
  `scripts/push_blocks`). Admin only.

  The hash comes from the bytes' own header, and the block goes through the
  sync loop's checks (`Bitblocks.Chain.BlockImport.import_bytes/2`): header
  hash and proof of work, txids rebuilt into the merkleroot, every tx stored.
  Only the height is taken from the caller, and a height held by a different
  block is refused.

  201 when the block was stored, 200 when it was already complete, 422 when
  the bytes aren't that block, 413 when the body is over the size cap.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain.BlockImport

  # The raw-block path holds a block in memory (Chain.RawBlock's cap).
  @max_bytes 64 * 1024 * 1024

  def create(conn, %{"height" => height}) do
    with {height, ""} <- Integer.parse(height),
         {:ok, bytes, conn} <- read_all(conn, []) do
      case BlockImport.import_bytes(height, bytes) do
        {:ok, :completed, hash} ->
          conn |> put_status(201) |> json(%{height: height, hash: hash, result: "completed"})

        {:ok, :already_complete, hash} ->
          json(conn, %{height: height, hash: hash, result: "already_complete"})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{error: inspect(reason)})
      end
    else
      {:too_large, conn} ->
        conn |> put_status(413) |> json(%{error: "block over #{@max_bytes} bytes"})

      _ ->
        conn |> put_status(422) |> json(%{error: "height must be a whole number"})
    end
  end

  defp read_all(conn, acc) do
    case Plug.Conn.read_body(conn, length: 8_000_000, read_timeout: 60_000) do
      {:ok, chunk, conn} ->
        finish([acc, chunk], conn)

      {:more, chunk, conn} ->
        if IO.iodata_length([acc, chunk]) > @max_bytes,
          do: {:too_large, conn},
          else: read_all(conn, [acc, chunk])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(iodata, conn) do
    if IO.iodata_length(iodata) > @max_bytes,
      do: {:too_large, conn},
      else: {:ok, IO.iodata_to_binary(iodata), conn}
  end
end
