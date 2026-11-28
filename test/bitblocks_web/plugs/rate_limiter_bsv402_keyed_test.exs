defmodule BitblocksWeb.Plugs.RateLimiterBsv402KeyedTest do
  @moduledoc """
  A caller with an API key past its own budget, paying in BSV (docs/BSV_402.md,
  slice B; qart's server first, https://github.com/afomi/qart/issues/383): the
  402 with BRC-121's terms where it was a 429 (the 429 while BSV 402 is off),
  a paid retry served outside the key's budget and metered under the key, a
  replay refused, the paid caps, a bad key still a 401, and the published
  keyed vectors, run through the plug.
  """
  # async: false: the limiter's ETS table, app config, env vars and RpcStub are global.
  use BitblocksWeb.ConnCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Bitblocks.ApiKeys
  alias Bitblocks.Bsv402Fixtures, as: F
  alias Bitblocks.Interop.{Brc42, Bsv402Vectors}
  alias Bitblocks.Payments.{Bsv402, BsvPayment}
  alias Bitblocks.Payments.X402, as: X402Pay
  alias Bitblocks.{RealHeaders, Repo}
  alias BitblocksWeb.RpcStub

  @env "BSV402_TEST_IDENTITY_KEY"
  @price 100
  @path "/api/v1/blocks/latest"

  # Block 0's only transaction, so its txid is the genesis merkle root.
  @genesis_coinbase Base.decode16!(
                      "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000",
                      case: :lower
                    )

  @doc_map Jason.decode!(Bsv402Vectors.body())

  setup do
    case :ets.whereis(:rate_limiter) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:rate_limiter)
    end

    limiter = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)
    bsv = Application.get_env(:bitblocks, Bsv402)
    x402 = Application.get_env(:bitblocks, X402Pay)
    env = System.get_env(@env)

    Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, max_requests: 100)
    System.put_env(@env, Base.encode16(F.server_private(), case: :lower))
    enable()
    RpcStub.setup()

    on_exit(fn ->
      Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, limiter)
      Application.put_env(:bitblocks, Bsv402, bsv)
      Application.put_env(:bitblocks, X402Pay, x402)
      if env, do: System.put_env(@env, env), else: System.delete_env(@env)
      RpcStub.clear()
    end)

    RealHeaders.insert(0)
    {:ok, key, token} = ApiKeys.create("qart", 1)
    %{key: key, token: token}
  end

  defp enable(enabled \\ true) do
    Application.put_env(:bitblocks, Bsv402,
      enabled: enabled,
      price_sats: Integer.to_string(@price),
      identity_key_env: @env
    )
  end

  defp server_key, do: F.server_private() |> Brc42.public_key() |> Base.encode16(case: :lower)

  defp payment do
    now = Integer.to_string(System.system_time(:millisecond))
    F.payment(@genesis_coinbase, 0, @price, time: now)
  end

  defp request(token, headers \\ [], path \\ @path) do
    build_conn()
    |> put_req_header("x-forwarded-for", "198.51.100.7")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> get(path)
  end

  defp quietly(fun) do
    {result, _log} = with_log(fun)
    result
  end

  # The key's sliding window: how many requests it has counted.
  defp counted(key) do
    case :ets.lookup(:rate_limiter, "key:#{key.id}") do
      [{_, stamps}] -> length(stamps)
      [] -> 0
    end
  end

  defp node_takes_it, do: RpcStub.stub_sendrawtransaction(String.duplicate("ab", 32))

  describe "within its budget" do
    test "a key is served free, and counted", %{key: key, token: token} do
      conn = request(token)

      assert conn.status == 200
      assert get_resp_header(conn, "x-ratelimit-limit") == ["1"]
      assert get_resp_header(conn, "x-bsv-sats") == []
      assert counted(key) == 1
    end
  end

  describe "past its budget" do
    test "with BSV 402 on: a 402 carrying BRC-121's terms, in JSON", %{token: token} do
      assert request(token).status == 200
      conn = quietly(fn -> request(token) end)

      assert conn.status == 402
      assert get_resp_header(conn, "x-bsv-sats") == [Integer.to_string(@price)]
      assert get_resp_header(conn, "x-bsv-server") == [server_key()]
      assert get_resp_header(conn, "x-ratelimit-limit") == ["1"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["0"]
      assert [_] = get_resp_header(conn, "retry-after")
      assert get_resp_header(conn, "payment-required") == []

      body = json_response(conn, 402)
      assert body["error"] == "api_key_rate_limited"
      assert body["budget"] == "api_key"
      assert body["limit_per_minute"] == 1
      assert body["crawler_family"] == nil
      assert body["ways_in"]["pay_in_bsv"]["protocol"] == "BRC-121"
    end

    test "with BSV 402 off: the 429 it always was", %{token: token} do
      enable(false)
      assert request(token).status == 200

      conn = quietly(fn -> request(token) end)
      assert conn.status == 429
      assert get_resp_header(conn, "x-bsv-sats") == []
    end

    test "with x402 on and BSV off: still the 429, since BSV is the requirement", %{token: token} do
      enable(false)
      x402_on()
      assert request(token).status == 200

      assert quietly(fn -> request(token) end).status == 429
    end

    test "with both on: x402's offer beside the terms", %{token: token} do
      x402_on()
      assert request(token).status == 200
      conn = quietly(fn -> request(token) end)

      assert conn.status == 402
      assert [_offer] = get_resp_header(conn, "payment-required")
      assert get_resp_header(conn, "x-bsv-sats") == [Integer.to_string(@price)]
    end

    test "a route the key doesn't open is never offered: the 429", %{token: token} do
      assert request(token, [], "/api/v1/ops/sync").status in [200, 403]

      conn = quietly(fn -> request(token, [], "/api/v1/ops/sync") end)
      assert conn.status == 429
      assert get_resp_header(conn, "x-bsv-sats") == []
    end
  end

  describe "a paid retry" do
    test "is served with what was paid, outside the key's budget, and metered under the key",
         %{key: key, token: token} do
      assert request(token).status == 200
      assert counted(key) == 1
      node_takes_it()
      paid = payment()

      conn = quietly(fn -> request(token, paid.headers) end)

      assert conn.status == 200
      assert get_resp_header(conn, "x-bsv-payment-satoshis-paid") == [Integer.to_string(@price)]
      assert get_resp_header(conn, "x-bsv-txid") == [paid.txid]

      # Not counted: the key's free allowance is as it was.
      assert counted(key) == 1
      assert quietly(fn -> request(token) end).status == 402

      # The usage meter books it under the key, and the payment's row names it.
      assert Bitblocks.Usage.caller(conn) == {"key", to_string(key.id)}
      row = Repo.get_by!(BsvPayment, txid: paid.txid)
      assert row.caller == "key:#{key.id}"
      assert row.status == "accepted"
      assert row.request_hash == Bsv402.request_hash("GET", @path, "")
    end

    test "its replay for another request is refused, with the terms again", %{token: token} do
      assert request(token).status == 200
      node_takes_it()
      paid = payment()

      assert quietly(fn -> request(token, paid.headers) end).status == 200

      replay = quietly(fn -> request(token, paid.headers, "/api/v1/blocks/0") end)
      assert replay.status == 402
      assert get_resp_header(replay, "x-bsv-refused") == ["replayed"]
      assert get_resp_header(replay, "x-bsv-sats") == [Integer.to_string(@price)]
      assert json_response(replay, 402)["payment_refused"]["reason"] == "replayed"
      assert Repo.aggregate(BsvPayment, :count) == 1
    end

    test "meets the shared paid caps, checked before the payment is read", %{token: token} do
      Application.put_env(:bitblocks, X402Pay,
        enabled: false,
        paid_per_ip_per_minute: 1,
        paid_site_per_minute: 600
      )

      assert request(token).status == 200
      node_takes_it()

      assert quietly(fn -> request(token, payment().headers) end).status == 200

      conn = quietly(fn -> request(token, payment().headers, "/api/v1/blocks/0") end)
      assert conn.status == 429
      assert [_] = get_resp_header(conn, "retry-after")
      assert length(RpcStub.calls(:sendrawtransaction)) == 1
    end
  end

  describe "a bad key" do
    test "is a 401, never a 402, even carrying a payment", %{key: key, token: token} do
      node_takes_it()

      bogus = quietly(fn -> request("bbk_not-a-real-key", payment().headers) end)
      assert bogus.status == 401
      assert get_resp_header(bogus, "x-bsv-sats") == []

      {:ok, _} = ApiKeys.revoke(key.id)
      revoked = quietly(fn -> request(token, payment().headers) end)
      assert revoked.status == 401
      assert get_resp_header(revoked, "x-bsv-txid") == []

      assert RpcStub.calls(:sendrawtransaction) == []
    end
  end

  # The published keyed vectors, through the plug, under the file's key, price,
  # clock and headers, and its stubbed node (handed to the verifier in the
  # conn's private).
  describe "the keyed vectors" do
    @held Map.new(@doc_map["headers"], fn header ->
            {header["height"],
             %{
               hash: "synthetic",
               merkleroot: header["merkleroot"],
               num_tx: header["tx_count"],
               verified: true,
               canonical: true
             }}
          end)

    defp node_answer("accept"), do: :accepted
    defp node_answer("already_known"), do: :already_known
    defp node_answer("unreachable"), do: :unavailable
    defp node_answer("reject:" <> reason), do: {:rejected, reason}

    defp vector_opts(vector) do
      answer = node_answer(vector["node"])

      [
        now_ms: @doc_map["now_ms"],
        max_beef_bytes: @doc_map["max_beef_bytes"],
        headers: fn heights -> Map.take(@held, heights) end,
        tip: @held |> Map.keys() |> Enum.max(),
        broadcast: fn _raw -> answer end
      ]
    end

    defp claim!(txid, request) do
      Repo.insert!(%BsvPayment{
        txid: txid,
        vout: 0,
        satoshis: @doc_map["price_sats"],
        sender_key: @doc_map["sender"]["identity_key"],
        derivation_prefix: "x",
        derivation_suffix: "x",
        raw_tx: <<0>>,
        request_hash: Bsv402.request_hash(request["method"], request["path"], request["query"]),
        price_sats: @doc_map["price_sats"],
        caller: @doc_map["sender"]["identity_key"],
        accepted_at: DateTime.utc_now()
      })
    end

    defp send_vector(vector, payment) do
      req = vector["request"]

      path =
        if req["query"] in [nil, ""], do: req["path"], else: req["path"] <> "?" <> req["query"]

      build_conn()
      |> put_req_header("x-forwarded-for", "198.51.100.8")
      |> put_private(:bsv402_opts, vector_opts(vector))
      |> then(fn conn ->
        Enum.reduce(Map.merge(vector["request_headers"], payment || %{}), conn, fn {k, v}, c ->
          put_req_header(c, k, v)
        end)
      end)
      |> dispatch(@endpoint, req["method"], path)
    end

    test "the file's server key and price are the ones these tests run under" do
      assert @doc_map["server"]["identity_key"] == server_key()
      assert @doc_map["price_sats"] == @price
    end

    test "cover what qart stubs: under budget, over, paid, replayed and a bad key" do
      ids = Enum.map(@doc_map["keyed"], & &1["id"])
      assert ids == ~w(keyed-under-budget keyed-over-budget keyed-pays keyed-replay keyed-bad-key)
    end

    for vector <- @doc_map["keyed"] do
      @vector vector
      test "#{vector["id"]}: #{vector["case"]}" do
        vector = @vector
        expected = vector["expected"]
        api_key = vector["api_key"]

        if api_key["registered"] do
          hash = :crypto.hash(:sha256, api_key["token"]) |> Base.encode16(case: :lower)
          {:ok, _} = ApiKeys.create_from_hash("vectors", api_key["requests_per_minute"], hash)
        end

        for _ <- List.duplicate(nil, api_key["spent"]) do
          assert send_vector(vector, nil).status == 200
        end

        for %{"txid" => txid, "request" => request} <- vector["claimed"],
            do: claim!(txid, request)

        conn = quietly(fn -> send_vector(vector, vector["payment"]) end)

        assert conn.status == expected["status"], vector["id"]

        for {name, value} <- expected["headers"] do
          assert get_resp_header(conn, name) == [value], "#{vector["id"]}: #{name}"
        end

        for name <- expected["headers_present"],
            do: assert([_] = get_resp_header(conn, name), "#{vector["id"]}: #{name}")

        for name <- expected["headers_absent"],
            do: assert(get_resp_header(conn, name) == [], "#{vector["id"]}: #{name}")

        if body = expected["body"] do
          assert subset?(body, Jason.decode!(conn.resp_body)), vector["id"]
        end
      end
    end

    defp subset?(want, got) when is_map(want) and is_map(got),
      do: Enum.all?(want, fn {k, v} -> Map.has_key?(got, k) and subset?(v, got[k]) end)

    defp subset?(want, got), do: want == got
  end

  defp x402_on do
    Application.put_env(:bitblocks, X402Pay,
      enabled: true,
      network: "eip155:84532",
      pay_to: "0x000000000000000000000000000000000000dEaD",
      price_atomic: 10_000,
      paid_per_ip_per_minute: 30,
      paid_site_per_minute: 600
    )
  end
end
