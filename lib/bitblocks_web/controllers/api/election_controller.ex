defmodule BitblocksWeb.Api.ElectionController do
  @moduledoc """
  `GET /api/v1/elections/:outpoint`, open, no key.

  The same gather and count as the page. A bad outpoint is 400, a missing
  record is 404, and a record we cannot count is 422, each `%{error: message}`.
  """
  use BitblocksWeb, :controller

  alias BitblocksWeb.ElectionCount

  @doc "GET /api/v1/elections/:outpoint"
  def show(conn, %{"outpoint" => outpoint}) do
    case ElectionCount.load(outpoint) do
      {:ok, count} ->
        json(conn, ElectionCount.api(count))

      {:error, status, message} ->
        conn |> put_status(status) |> json(%{error: message})
    end
  end
end
