defmodule BitblocksWeb.Api.BitcomControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.BitcomFixtures

  setup do
    admin = BSV.PrivKey.new()
    %{admin: admin, admin_addr: address(admin)}
  end

  test "GET /api/v1/bitcom exports every namespace", %{conn: conn} = ctx do
    {proof, _} = bitcom_command_fixture(ctx.admin, [["$", "useradd", ctx.admin_addr]])

    body = conn |> get(~p"/api/v1/bitcom") |> json_response(200)

    assert body["spec"] == "https://github.com/unwriter/Bitcom"
    entry = Enum.find(body["namespaces"], &(&1["address"] == ctx.admin_addr))
    assert entry["tier"] == "proven"
    assert entry["proof_txid"] == proof.txid
  end

  test "GET /bitcom.json serves the same export", %{conn: conn} do
    assert %{"namespaces" => namespaces} = conn |> get("/bitcom.json") |> json_response(200)
    assert is_list(namespaces)
  end

  test "GET /api/v1/bitcom/:address returns one namespace", %{conn: conn} = ctx do
    bitcom_command_fixture(ctx.admin, [["$", "echo", "hi", "to", "readme"]])

    data =
      conn |> get(~p"/api/v1/bitcom/#{ctx.admin_addr}") |> json_response(200) |> Map.get("data")

    assert data["tier"] == "self_described"
    assert [%{"file" => "readme", "content" => "hi"}] = data["files"]
  end

  describe "GET /api/v1/bit/:address/*path" do
    test "resolves to each provider's instantiated endpoint", %{conn: conn} = ctx do
      provider = BSV.PrivKey.new()
      tx = String.duplicate("e", 64)
      bitcom_command_fixture(ctx.admin, [["$", "route", "enable", "/:tx"]], salt: 1)

      bitcom_command_fixture(
        provider,
        [["$", "route", "add", ctx.admin_addr, "/:tx", "https://media.example/${tx}"]],
        salt: 2
      )

      data =
        conn
        |> get("/api/v1/bit/#{ctx.admin_addr}/#{tx}")
        |> json_response(200)
        |> Map.get("data")

      assert data["uri"] == "bit://#{ctx.admin_addr}/#{tx}"
      assert data["matcher"] == "/:tx"
      assert [%{"url" => url, "provider" => p}] = data["endpoints"]
      assert url == "https://media.example/#{tx}"
      assert p == address(provider)
    end

    test "404s when no enabled route matches", %{conn: conn} = ctx do
      assert %{"error" => "No enabled route matches"} =
               conn |> get("/api/v1/bit/#{ctx.admin_addr}/anything") |> json_response(404)
    end
  end

  describe "POST /api/v1/bitcom/compose" do
    test "returns the unsigned script", %{conn: conn} = ctx do
      body =
        conn
        |> post("/api/v1/bitcom/compose", %{
          funder: ctx.admin_addr,
          pushes: ["echo", "hi", "to", "readme"]
        })
        |> json_response(200)

      assert body["data"]["script_hex"] =~ ~r/^006a0124/
      assert body["data"]["namespace"] == ctx.admin_addr
    end

    test "422s on an invalid command", %{conn: conn} = ctx do
      assert %{"error" => "malformed echo"} =
               conn
               |> post("/api/v1/bitcom/compose", %{funder: ctx.admin_addr, pushes: ["echo"]})
               |> json_response(422)
    end
  end

  test "rejects an invalid address", %{conn: conn} do
    assert %{"error" => "Invalid address"} =
             conn |> get(~p"/api/v1/bitcom/nope") |> json_response(400)
  end
end
