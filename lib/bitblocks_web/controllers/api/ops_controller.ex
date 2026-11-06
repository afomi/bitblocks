defmodule BitblocksWeb.Api.OpsController do
  @moduledoc """
  The operator API (#50): read-only views of `Bitblocks.Ops`, for a key with
  the `ops_read` scope (`BitblocksWeb.Plugs.RequireScope`). The same tools are
  served over MCP by `BitblocksWeb.Api.OpsMcpController`.

  Every answer is scrubbed in `Bitblocks.Ops`, and none may be cached.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Ops

  def sync(conn, _params), do: answer(conn, Ops.sync_live())

  def node_report(conn, _params), do: answer(conn, Ops.node_report())

  def errors(conn, params), do: answer(conn, Ops.errors(limit(params["limit"])))

  def block(conn, %{"height" => height}) do
    case Integer.parse(height) do
      {height, ""} when height >= 0 ->
        case Ops.block(height) do
          nil -> conn |> put_status(404) |> answer(%{error: "No stored block at that height"})
          story -> answer(conn, story)
        end

      _ ->
        conn |> put_status(400) |> answer(%{error: "A block height is a whole number"})
    end
  end

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp limit(_), do: nil

  defp answer(conn, body) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> json(body)
  end
end
