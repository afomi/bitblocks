defmodule BitblocksWeb.Api.BitcomController do
  @moduledoc """
  The Bitcom registry as JSON (see `Bitblocks.Bitcom`).

    * `GET /api/v1/bitcom` and `GET /bitcom.json` — every namespace, with the
      txids needed to re-verify each entry from the chain.
    * `GET /api/v1/bitcom/:address` — one namespace.
    * `GET /api/v1/bitcom/snapshots` — every versioned snapshot, newest first.
    * `GET /api/v1/bitcom/snapshots/:version` — one snapshot's exact bytes, or
      `latest`; `sha256sum` of the body matches the listed hash.
    * `POST /api/v1/bitcom/compose` — `{"funder", "pushes"}` → the unsigned
      OP_RETURN script for a wallet to sign (pushes exclude the `$`).
    * `GET /api/v1/bit/:address/*path` — resolves `bit://<address>/<path>` to
      the endpoints providers registered for it.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Bitcom
  alias Bitblocks.Bitcom.Snapshots

  def index(conn, _params), do: json(conn, Bitcom.export())

  def snapshots(conn, _params), do: json(conn, %{data: Snapshots.list()})

  def snapshot(conn, %{"version" => version}) do
    case find_snapshot(version) do
      nil ->
        conn |> put_status(404) |> json(%{error: "No such snapshot"})

      snapshot ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("x-bitcom-snapshot-version", to_string(snapshot.id))
        |> put_resp_header("x-bitcom-snapshot-sha256", snapshot.sha256)
        |> snapshot_cache(version)
        |> send_resp(200, snapshot.body)
    end
  end

  defp find_snapshot("latest"), do: Snapshots.latest()

  defp find_snapshot(version) do
    case Integer.parse(String.replace_suffix(version, ".json", "")) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> Snapshots.get(id)
      _ -> nil
    end
  end

  # A numbered version never changes.
  defp snapshot_cache(conn, "latest"), do: conn

  defp snapshot_cache(conn, _version),
    do: put_resp_header(conn, "cache-control", "public, max-age=31536000, immutable")

  def show(conn, %{"address" => address}) do
    if Bitcom.address?(address),
      do: json(conn, %{data: Bitcom.export_namespace(address)}),
      else: conn |> put_status(400) |> json(%{error: "Invalid address"})
  end

  def resolve(conn, %{"address" => address, "path" => segments}) do
    path = "/" <> Enum.join(segments, "/") <> query_suffix(conn.query_string)
    uri = "bit://" <> address <> path

    with true <- Bitcom.address?(address),
         {:ok, resolved} <- Bitcom.resolve(address, path) do
      json(conn, %{data: Map.put(resolved, :uri, uri)})
    else
      false ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})

      {:error, :no_route} ->
        conn |> put_status(404) |> json(%{error: "No enabled route matches", uri: uri})
    end
  end

  def compose(conn, %{"funder" => funder, "pushes" => pushes})
      when is_binary(funder) and is_list(pushes) do
    case Bitcom.compose(pushes, funder) do
      {:ok, out} -> json(conn, %{data: out})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: reason})
    end
  end

  def compose(conn, _params),
    do:
      conn
      |> put_status(400)
      |> json(%{error: "Expected {\"funder\": string, \"pushes\": [string]}"})

  defp query_suffix(""), do: ""
  defp query_suffix(query), do: "?" <> query
end
