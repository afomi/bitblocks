defmodule BitblocksWeb.DownloadFileController do
  @moduledoc """
  A paid download's manifest and links, for the buyer's browser and their
  script (https://github.com/afomi/bitblocks/issues/111):

    * `GET /downloads/:id/manifest.json`: every file with its height, block
      hash, merkleroot, bytes and sha256 (`Purchases.manifest_stream/1`),
      streamed in chunks, with its sha256 in `x-manifest-sha256`.
    * `GET /downloads/:id/links.tsv?from=<height>`: the next batch of files
      from that height, one per line: height, block hash, bytes, sha256,
      file name, and a signed link good for 15 minutes (`Purchases.links/3`).
      An empty body means there are no more.

  Either takes the owner's session, or `?token=`, a signed token from the
  download page good for #{div(604_800, 86_400)} days (`token/1`), so a script can run
  where the browser isn't. Anything else is a 404, which says nothing about
  whether the purchase exists. Links are issued only while the purchase is
  paid, prepared and within its 30 days; otherwise a 410 that says why.
  The bytes themselves never pass through here: each link goes straight to
  the store.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Downloads.Purchases

  @salt "download purchase"
  @token_max_age 604_800

  @doc "A token for a purchase's script, good for 7 days."
  def token(purchase_id), do: Phoenix.Token.sign(BitblocksWeb.Endpoint, @salt, purchase_id)

  @doc "Seconds a script token is good for."
  def token_max_age, do: @token_max_age

  def manifest(conn, %{"id" => id} = params) do
    with {:ok, purchase} <- authorize(conn, id, params),
         :ok <- ready(purchase) do
      conn =
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="bitblocks-download-#{purchase.id}-manifest.json")
        )
        |> put_resp_header("x-manifest-sha256", purchase.manifest_sha256 || "")
        |> put_resp_header("cache-control", "private, no-store")
        |> send_chunked(200)

      Enum.reduce_while(Purchases.manifest_stream(purchase), conn, fn chunk, conn ->
        case chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, :closed} -> {:halt, conn}
        end
      end)
    else
      error -> refuse(conn, error)
    end
  end

  def links(conn, %{"id" => id} = params) do
    with {:ok, purchase} <- authorize(conn, id, params),
         {:ok, from} <- from_height(params["from"], purchase.from_height),
         {:ok, files} <- Purchases.links(purchase, from) do
      body =
        Enum.map(files, fn f ->
          [
            Integer.to_string(f.height),
            "\t",
            f.block_hash,
            "\t",
            Integer.to_string(f.bytes),
            "\t",
            f.sha256 || "",
            "\t",
            f.name,
            "\t",
            f.url,
            "\n"
          ]
        end)

      conn
      |> put_resp_content_type("text/tab-separated-values")
      |> put_resp_header("cache-control", "private, no-store")
      |> send_resp(200, body)
    else
      error -> refuse(conn, error)
    end
  end

  defp authorize(conn, id, params) do
    purchase = Purchases.get(id)

    cond do
      is_nil(purchase) -> {:error, :not_found}
      owner?(conn, purchase) -> {:ok, purchase}
      token_valid?(params["token"], purchase.id) -> {:ok, purchase}
      true -> {:error, :not_found}
    end
  end

  defp owner?(conn, purchase) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> user_id == purchase.user_id
      _ -> false
    end
  end

  defp token_valid?(token, purchase_id) when is_binary(token) do
    Phoenix.Token.verify(BitblocksWeb.Endpoint, @salt, token, max_age: @token_max_age) ==
      {:ok, purchase_id}
  end

  defp token_valid?(_, _), do: false

  defp ready(purchase) do
    if Purchases.downloadable?(purchase), do: :ok, else: {:error, :not_downloadable}
  end

  defp from_height(nil, default), do: {:ok, default}
  defp from_height("", default), do: {:ok, default}

  defp from_height(s, _default) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :bad_from}
    end
  end

  defp refuse(conn, {:error, :not_found}),
    do: conn |> put_status(404) |> text("Not found\n")

  defp refuse(conn, {:error, :bad_from}),
    do: conn |> put_status(400) |> text("from must be a block height\n")

  defp refuse(conn, {:error, :not_downloadable}) do
    conn
    |> put_status(410)
    |> text("These files can't be downloaded now. Open the download page to see why.\n")
  end

  defp refuse(conn, {:error, _}),
    do: conn |> put_status(503) |> text("Links are unavailable right now. Try again shortly.\n")
end
