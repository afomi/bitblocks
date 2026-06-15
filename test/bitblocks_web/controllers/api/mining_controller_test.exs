defmodule BitblocksWeb.Api.MiningControllerTest do
  use BitblocksWeb.ConnCase, async: true

  # The mining proxy is disabled by default, so a *valid* submission resolves to
  # a graceful "no work" rather than touching the node. These tests focus on the
  # input-validation boundary (threat T11): malformed nonce/timestamp must return
  # 400, never crash the request.

  describe "POST /api/v1/mining/submit — input bounds (threat T11)" do
    test "rejects a non-numeric nonce with 400 (was a String.to_integer crash)", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/mining/submit", %{
          "work_id" => "abc",
          "nonce" => "not-a-number",
          "timestamp" => "1700000000"
        })

      assert json_response(conn, 400)["error"] =~ "unsigned 32-bit"
    end

    test "rejects an out-of-range nonce with 400 (was a ::little-32 binary crash)", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/mining/submit", %{
          "work_id" => "abc",
          # 2^32, one past the u32 ceiling
          "nonce" => "4294967296",
          "timestamp" => "1700000000"
        })

      assert json_response(conn, 400)["error"] =~ "unsigned 32-bit"
    end

    test "rejects a negative timestamp with 400", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/mining/submit", %{
          "work_id" => "abc",
          "nonce" => "0",
          "timestamp" => "-1"
        })

      assert json_response(conn, 400)["error"] =~ "unsigned 32-bit"
    end

    test "missing fields returns 400", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/mining/submit", %{"work_id" => "abc"})
      assert json_response(conn, 400)["error"] =~ "Missing required fields"
    end

    test "valid u32 values pass validation (resolve to no-work since proxy is off)", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/mining/submit", %{
          "work_id" => "abc",
          "nonce" => "42",
          "timestamp" => "1700000000"
        })

      # Past the validation gate: not a 400. With the proxy disabled this is a
      # 503 "no work" (or another non-400 rejection) — the point is no crash.
      refute conn.status == 400
      refute conn.status == 500
    end
  end
end
