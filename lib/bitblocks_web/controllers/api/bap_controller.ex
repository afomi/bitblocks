defmodule BitblocksWeb.Api.BapController do
  @moduledoc """
  BAP identities over HTTP (#32, docs/BAP.md). Public chain data, read-only.

    * `GET /api/v1/bap/:bap_id` — the identity: first record, rotations,
      current address and current profile.
    * `GET /api/v1/bap/:bap_id/attestations` — what the identity attested.
    * `GET /api/v1/bap?address=` — the identities an address signs for.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Bap

  action_fallback BitblocksWeb.FallbackController

  def index(conn, %{"address" => address}) when is_binary(address) do
    json(conn, %{data: Bap.by_address(address)})
  end

  def index(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Name a signing address: ?address="})
  end

  def show(conn, %{"bap_id" => bap_id}) do
    case Bap.identity(bap_id) do
      nil -> {:error, :not_found}
      identity -> json(conn, %{data: Map.delete(identity, :keys)})
    end
  end

  def attestations(conn, %{"bap_id" => bap_id}) do
    case Bap.attestations(bap_id) do
      nil -> {:error, :not_found}
      attestations -> json(conn, %{data: attestations})
    end
  end
end
