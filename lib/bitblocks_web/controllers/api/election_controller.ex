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

  @doc """
  GET /api/v1/elections/:outpoint/ballots/:query: one ballot by txid, or an
  address's ballots in chain order and which one counts, as the page answers
  it (`ElectionCount.lookup/2`). A query that is neither is a 400.
  """
  def ballot(conn, %{"outpoint" => outpoint, "query" => query}) do
    with {:ok, count} <- ElectionCount.load(outpoint),
         {:ok, answer} <- lookup(count, query) do
      json(conn, ElectionCount.lookup_api(count, answer))
    else
      {:error, status, message} ->
        conn |> put_status(status) |> json(%{error: message})
    end
  end

  defp lookup(count, query) do
    case ElectionCount.lookup(count, query) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> {:error, 400, ElectionCount.lookup_message(reason)}
    end
  end
end
