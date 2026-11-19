defmodule BitblocksWeb.Plugs.MeterTest do
  @moduledoc """
  Every request through the endpoint is metered under its caller and class
  (https://github.com/afomi/bitblocks/issues/61), refusals included, and a
  key holder can read their own usage at `GET /api/v1/usage`.
  """
  # async: false: the counters' ETS table and the limiter's config are global.
  use BitblocksWeb.ConnCase, async: false

  alias Bitblocks.{ApiKeys, Usage}

  setup do
    {:ok, key, token} = ApiKeys.create("meter-test", 3)
    %{key: key, token: token}
  end

  defp keyed(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  test "a keyed API read is counted under its key, with bytes and DB time", %{
    key: key,
    token: token
  } do
    conn = get(keyed(token), "/api/v1/blocks")
    assert conn.status == 200

    %{totals: t, by_class: [read]} = Usage.caller_usage({"key", to_string(key.id)})
    assert read.class == "read"
    assert t.requests == 1
    assert t.response_bytes == byte_size(conn.resp_body)
    assert t.db_queries >= 1
    assert t.duration_us > 0
  end

  test "a request the limiter refuses is counted as a 4xx for the key", %{key: key, token: token} do
    :ets.delete_all_objects(:rate_limiter)
    statuses = for _ <- 1..4, do: get(keyed(token), "/api/v1/blocks").status
    assert statuses == [200, 200, 200, 429]

    %{totals: t} = Usage.caller_usage({"key", to_string(key.id)})
    assert t.requests == 4
    assert t.status_4xx == 1
  end

  test "a raw tx and a missing proof land in their own classes", %{key: key, token: token} do
    txid = String.duplicate("e", 64)
    get(keyed(token), "/api/v1/txs/#{txid}/raw")
    get(keyed(token), "/api/v1/txs/#{txid}/proof")

    %{by_class: classes} = Usage.caller_usage({"key", to_string(key.id)})
    assert Enum.map(classes, & &1.class) == ["raw_export", "proof"]
    assert Enum.all?(classes, &(&1.requests == 1))
  end

  describe "GET /api/v1/usage" do
    test "shows the key its own usage, by class", %{key: key, token: token} do
      get(keyed(token), "/api/v1/blocks")

      body = keyed(token) |> get("/api/v1/usage?hours=24") |> json_response(200)

      assert body["meta"]["caller"] == "key"
      assert body["meta"]["hours"] == 24
      assert body["meta"]["note"] =~ "not billed"
      assert [%{"class" => "read", "requests" => 1}] = body["data"]["by_class"]
      assert body["data"]["totals"]["requests"] == 1
      refute inspect(body) =~ to_string(key.prefix)
    end

    test "is refused without a key or session, and checks hours", %{token: token} do
      assert build_conn() |> get("/api/v1/usage") |> json_response(401)
      assert keyed(token) |> get("/api/v1/usage?hours=0") |> json_response(400)
      assert keyed(token) |> get("/api/v1/usage?hours=721") |> json_response(400)
    end
  end
end
