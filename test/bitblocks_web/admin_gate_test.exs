defmodule BitblocksWeb.AdminGateTest do
  @moduledoc """
  Verifies the operator surface is gated in every env.

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
    test "GET /sync with no session is refused", %{conn: conn} do
      conn = get(conn, ~p"/sync")

      refute conn.status == 200
      assert conn.halted
    end

    test "GET /metrics with no session is refused", %{conn: conn} do
      conn = get(conn, "/metrics")

      refute conn.status == 200
      assert conn.halted
    end

    test "a non-admin user is refused", %{conn: conn} do
      user = Bitblocks.Repo.insert!(%Bitblocks.Accounts.User{github_id: 7_001, login: "reader"})
      conn = conn |> init_test_session(%{"user_id" => user.id}) |> get(~p"/sync")

      assert conn.status == 403
    end

    test "an admin passes", %{conn: conn} do
      user =
        Bitblocks.Repo.insert!(%Bitblocks.Accounts.User{
          github_id: 7_002,
          login: "operator",
          admin: true
        })

      conn = conn |> init_test_session(%{"user_id" => user.id}) |> get(~p"/sync")

      assert conn.status == 200
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
