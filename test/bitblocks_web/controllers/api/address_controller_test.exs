defmodule BitblocksWeb.Api.AddressControllerTest do
  use BitblocksWeb.ConnCase, async: true

  # These exercise the validation gate (threat T7) — a rejected address never
  # reaches the outbound WhatsOnChain proxy, so no network call is made.

  describe "GET /api/v1/addresses/:address/utxos — validation" do
    test "rejects an address with base58-invalid characters", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/addresses/1BvBMSEYst0OIlInvalid/utxos")
      assert json_response(conn, 400)["error"] == "Invalid address"
    end

    test "rejects an over-long address", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/addresses/#{String.duplicate("a", 60)}/utxos")
      assert json_response(conn, 400)["error"] == "Invalid address"
    end
  end

  describe "GET /api/v1/addresses/:address/balance — validation" do
    test "rejects an address with base58-invalid characters", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/addresses/1BvBMSEYst0OIlInvalid/balance")
      assert json_response(conn, 400)["error"] == "Invalid address"
    end
  end
end
