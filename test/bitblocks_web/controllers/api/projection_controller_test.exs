defmodule BitblocksWeb.Api.ProjectionControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Projections

  @donation "1DonationAddressXXXXXXXXXXXXXXXXX"

  setup do
    {:ok, p} =
      Projections.create(%{
        tenant: "visible-dao",
        name: "donations",
        filter: %{"output_addresses" => [@donation]}
      })

    block_fixture(%{height: 30})

    for {height, n} <- [{10, 1}, {20, 2}, {30, 3}] do
      transaction_fixture(%{
        block_height: height,
        txid: String.duplicate("#{n}", 64),
        output_addresses: [@donation]
      })
    end

    %{projection: p}
  end

  test "GET /api/v1/projections/:id describes the projection", %{conn: conn, projection: p} do
    data = conn |> get(~p"/api/v1/projections/#{p.id}") |> json_response(200) |> Map.get("data")

    assert data["tenant"] == "visible-dao"
    assert data["filter"] == %{"output_addresses" => [@donation]}
    assert data["definition_hash"] == p.definition_hash
  end

  test "GET /api/v1/projections/:id/txs pages history with a cursor", %{conn: conn, projection: p} do
    first = conn |> get(~p"/api/v1/projections/#{p.id}/txs?limit=2") |> json_response(200)

    assert Enum.map(first["data"], & &1["block_height"]) == [10, 20]
    assert first["meta"]["snapshot_height"] == 30
    assert [%{"proof_url" => "/api/v1/txs/" <> _, "raw" => "some raw"} | _] = first["data"]

    cursor = first["meta"]["next_cursor"]

    second =
      build_conn()
      |> get(~p"/api/v1/projections/#{p.id}/txs?#{[cursor: cursor, limit: 2]}")
      |> json_response(200)

    assert Enum.map(second["data"], & &1["block_height"]) == [30]
    assert second["meta"]["next_cursor"] == nil
  end

  test "a bad cursor is a 400, an unknown projection a 404", %{conn: conn, projection: p} do
    assert %{"error" => "Invalid cursor" <> _} =
             conn |> get(~p"/api/v1/projections/#{p.id}/txs?cursor=nope") |> json_response(400)

    assert build_conn() |> get(~p"/api/v1/projections/0/txs") |> json_response(404)
    assert build_conn() |> get(~p"/api/v1/projections/abc") |> json_response(404)
  end
end
