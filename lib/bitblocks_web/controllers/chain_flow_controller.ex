defmodule BitblocksWeb.ChainFlowController do
  @moduledoc """
  The transaction graph for a block range (`Bitblocks.ChainFlow`), read by the
  `/tx-graph` flow space. Admin only (`:admin_data`).

      GET /chain-scrubber/flow?from=0&to=999
  """

  use BitblocksWeb, :controller

  alias Bitblocks.ChainFlow

  def show(conn, params) do
    with {:ok, from} <- height(params["from"]),
         {:ok, to} <- height(params["to"]),
         {:ok, payload} <- ChainFlow.range(from, to) do
      conn
      |> put_resp_header("cache-control", "private, no-cache")
      |> json(payload)
    else
      {:error, :timeout} ->
        conn
        |> put_status(503)
        |> json(%{error: "timeout", hint: "Try a smaller range."})

      _ ->
        conn
        |> put_status(400)
        |> json(%{error: "Give from and to as block heights, from <= to."})
    end
  end

  defp height(text) when is_binary(text) do
    case Integer.parse(text) do
      {h, ""} when h >= 0 -> {:ok, h}
      _ -> :error
    end
  end

  defp height(_), do: :error
end
