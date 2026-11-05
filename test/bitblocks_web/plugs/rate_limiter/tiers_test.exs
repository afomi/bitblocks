defmodule BitblocksWeb.Plugs.RateLimiter.TiersTest do
  @moduledoc """
  A caller's budget goes by who is asking: logged out by IP, logged in and
  admin by user, an API key by the key.
  """
  # async: false: the limiter's ETS table and config are global.
  use BitblocksWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Bitblocks.Accounts.User
  alias Bitblocks.ApiKeys
  alias Bitblocks.Repo

  setup do
    :ets.delete_all_objects(:rate_limiter)

    previous = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)

    Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter,
      max_requests: 2,
      signed_in_max_requests: 4,
      admin_max_requests: 6
    )

    on_exit(fn -> Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, previous) end)
  end

  defp user!(attrs \\ []) do
    id = System.unique_integer([:positive])
    Repo.insert!(struct!(%User{github_id: id, login: "user#{id}"}, attrs))
  end

  defp as(nil), do: build_conn()
  defp as(id), do: init_test_session(build_conn(), %{"user_id" => id})

  defp hit(id, ip \\ {10, 0, 0, 1}) do
    %{as(id) | remote_ip: ip} |> get("/api/v1/blocks")
  end

  defp limit_of(conn), do: get_resp_header(conn, "x-ratelimit-limit")

  test "logged out, logged in and admin each get their own budget" do
    assert limit_of(hit(nil)) == ["2"]
    assert limit_of(hit(user!().id)) == ["4"]
    assert limit_of(hit(user!(admin: true).id)) == ["6"]
  end

  test "a user's budget follows the user across addresses, and leaves the IP's alone" do
    user = user!()

    statuses = for n <- 1..5, do: hit(user.id, {10, 0, 0, n}).status
    assert statuses == [200, 200, 200, 200, 429]

    assert hit(nil, {10, 0, 0, 1}).status == 200
  end

  test "an admin is limited too, and the refusal names the tier and the limit" do
    admin = user!(admin: true)

    for _ <- 1..6, do: assert(hit(admin.id).status == 200)

    log = capture_log(fn -> assert hit(admin.id).status == 429 end)
    assert log =~ "user:#{admin.id} tier=admin limit=6"
  end

  test "a session whose user is gone gets the IP's budget" do
    assert limit_of(hit(-1)) == ["2"]
  end

  test "a forged session cookie gets the IP's budget" do
    conn = build_conn() |> put_req_cookie("_bitblocks_key", "forged") |> get("/api/v1/blocks")

    assert limit_of(conn) == ["2"]
  end

  test "a valid API key wins over the session" do
    {:ok, _key, token} = ApiKeys.create("cdn", 9)

    conn =
      user!(admin: true).id
      |> as()
      |> put_req_header("x-api-key", token)
      |> get("/api/v1/blocks")

    assert limit_of(conn) == ["9"]
  end

  test "the tier is cached, so a revoke lands when the cache lapses" do
    admin = user!(admin: true)
    assert limit_of(hit(admin.id)) == ["6"]

    admin |> Ecto.Changeset.change(admin: false) |> Repo.update!()
    assert limit_of(hit(admin.id)) == ["6"]

    :ets.delete(:rate_limiter, {:tier, admin.id})
    assert limit_of(hit(admin.id)) == ["4"]
  end

  test "the health check and the LiveView long poll aren't counted" do
    assert limit_of(get(build_conn(), "/healthz")) == []
    assert limit_of(get(build_conn(), "/live/longpoll")) == []
  end
end
