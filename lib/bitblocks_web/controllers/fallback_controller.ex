defmodule BitblocksWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use BitblocksWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: BitblocksWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end

  def call(conn, {:error, :invalid_cursor}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid cursor — pass back meta.next_cursor unchanged"})
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Unauthorized"})
  end

  def call(conn, {:error, :invalid_scripthash}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid scripthash — expected 64 hex chars (sha256, Electrum convention)"})
  end

  def call(conn, {:error, :invalid_script_hex}) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "Invalid script — expected a hex-encoded scriptPubKey in the \"script\" field"
    })
  end
end
