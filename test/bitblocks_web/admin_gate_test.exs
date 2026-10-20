defmodule BitblocksWeb.AdminGateTest do
  @moduledoc """
  Verifies the operator surface is gated by basic auth in every env.

  Test env normally bypasses the gate (`config :bitblocks, :admin_auth,
  enabled: false` in config/test.exs); these tests re-enable it for their own
  duration and restore the previous value on exit. async: false because the
  flag is global application env.
  """
  use BitblocksWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:bitblocks, :admin_auth)
    Application.put_env(:bitblocks, :admin_auth, enabled: true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bitblocks, :admin_auth)
        value -> Application.put_env(:bitblocks, :admin_auth, value)
      end
    end)

    :ok
  end

  describe "operator surface with admin_auth enabled" do
    test "GET /sync without credentials is refused with 401", %{conn: conn} do
      conn = get(conn, ~p"/sync")

      assert conn.status == 401
      assert conn.halted
      assert [_challenge | _] = get_resp_header(conn, "www-authenticate")
    end

    test "GET /sync with valid credentials renders", %{conn: conn} do
      {:ok, user, pass} = BitblocksWeb.AdminAuth.decision()

      conn =
        conn
        |> put_req_header("authorization", "Basic " <> Base.encode64("#{user}:#{pass}"))
        |> get(~p"/sync")

      assert conn.status == 200
    end

    test "GET /sync with wrong credentials is refused with 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic " <> Base.encode64("nope:wrong"))
        |> get(~p"/sync")

      assert conn.status == 401
    end

    test "GET /metrics without credentials is refused with 401", %{conn: conn} do
      conn = get(conn, "/metrics")

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "operator surface with admin_auth disabled (test default)" do
    test "GET /sync without credentials renders", %{conn: conn} do
      Application.put_env(:bitblocks, :admin_auth, enabled: false)

      conn = get(conn, ~p"/sync")

      assert conn.status == 200
    end
  end
end
