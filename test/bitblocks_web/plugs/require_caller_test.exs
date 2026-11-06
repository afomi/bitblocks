defmodule BitblocksWeb.Plugs.RequireCallerTest do
  @moduledoc """
  The API answers an API key or a signed-in session (#12); the rest is a 401,
  apart from the routes other sites, the deploy check and registry readers use without one.
  """
  # async: false: the gate and the limiter's table are global.
  use BitblocksWeb.ConnCase, async: false

  alias Bitblocks.Accounts.User
  alias Bitblocks.ApiKeys
  alias Bitblocks.Repo

  @txid String.duplicate("a", 64)

  setup do
    :ets.delete_all_objects(:rate_limiter)

    previous = Application.get_env(:bitblocks, :admin_auth)
    Application.put_env(:bitblocks, :admin_auth, enabled: true)
    on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, previous) end)
  end

  defp signed_in do
    id = System.unique_integer([:positive])
    user = Repo.insert!(%User{github_id: id, login: "user#{id}"})
    init_test_session(build_conn(), %{"user_id" => user.id})
  end

  defp keyed do
    {:ok, _key, token} = ApiKeys.create("gate-test", 100)
    put_req_header(build_conn(), "authorization", "Bearer #{token}")
  end

  for path <- [
        "/api/v1/blocks",
        "/api/v1/txs",
        "/api/v1/types",
        "/api/v1/tokens",
        "/api/v1/status/derivations",
        "/api/v1/stream/blocks",
        "/api/v1/bitcom",
        "/api/v1/txs/#{String.duplicate("a", 64)}/raw"
      ] do
    test "signed out, GET #{path} is a 401", %{conn: conn} do
      conn = get(conn, unquote(path))
      assert conn.status == 401
      assert json_response(conn, 401)["error"] =~ "API key"
    end
  end

  test "signed out, a POST is a 401 too", %{conn: conn} do
    conn = post(conn, "/api/v1/script/decode", %{hex: "51"})
    assert conn.status == 401
  end

  test "a signed-in session reaches the API" do
    assert signed_in() |> get("/api/v1/blocks") |> Map.fetch!(:status) == 200
  end

  test "an API key reaches the API" do
    assert keyed() |> get("/api/v1/blocks") |> Map.fetch!(:status) == 200
  end

  test "a key reaches a tx's raw route, past the gate to its own 404" do
    assert keyed() |> get("/api/v1/txs/#{@txid}/raw") |> Map.fetch!(:status) == 404
  end

  test "a session whose user is gone is a 401", %{conn: conn} do
    conn = conn |> init_test_session(%{"user_id" => -1}) |> get("/api/v1/blocks")
    assert conn.status == 401
  end

  test "the open routes need no key", %{conn: conn} do
    for path <- [
          "/api/v1/price/bsv",
          "/api/v1/support",
          "/api/v1/status",
          "/bitcom.json",
          "/api/v1/bitcom/snapshots"
        ] do
      refute get(conn, path).status == 401, "#{path} asked for a caller"
    end
  end

  test "pages and inscription content stay open", %{conn: conn} do
    assert get(conn, "/blocks").status == 200
    refute get(conn, "/content/#{@txid}_0").status == 401
  end
end
