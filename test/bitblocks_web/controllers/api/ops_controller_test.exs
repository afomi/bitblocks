defmodule BitblocksWeb.Api.OpsControllerTest do
  # The operator API (#50): read-only views of Bitblocks.Ops for a key with the
  # ops_read scope, and nothing that shouldn't leave the app.
  use BitblocksWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  require Logger

  alias Bitblocks.{ApiKeys, Ops, Repo, SyncProgress}
  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Ops.ErrorLog
  alias Bitblocks.Reorgs.Reorg

  # Every leak the tests below plant, and must not find in any answer.
  @rpc_user "nodeoperator"
  @rpc_password "correct-horse-battery"
  @node_url "http://nodeoperator:correct-horse-battery@10.20.30.40:8332"
  @private_ip "10.20.30.40"
  @env_secret "ops-test-env-secret-value"
  @address "1BAPSuaPnfGnSBM3GLV9yhxUdYe4vGbdMT"
  @planted_error "econnrefused at #{@node_url} via bitblocks@10.20.30.40 for #{@address} with #{@env_secret}"
  @leaks [
    @rpc_user,
    @rpc_password,
    @private_ip,
    @env_secret,
    @address,
    "8332",
    "bitblocks@",
    "{10, 20, 30, 40}"
  ]

  defmodule DownNode do
    @moduledoc false
    def getblockchaininfo, do: {:error, "econnrefused at " <> url()}
    def rest_chaininfo, do: {:error, {:connection_error, "no route to " <> url()}}
    defp url, do: Application.get_env(:bitblocks, :rpc_url)
  end

  defmodule UpNode do
    @moduledoc false
    def getblockchaininfo do
      %{"chain" => "main", "blocks" => 900, "headers" => 901, "verificationprogress" => 0.99}
    end

    def rest_chaininfo, do: {:ok, "{}"}
  end

  setup do
    keys = [:rpc_user, :rpc_password, :rpc_url, :bitcoinsv_cli]
    previous = Map.new(keys, &{&1, Application.get_env(:bitblocks, &1)})

    Application.put_env(:bitblocks, :rpc_user, @rpc_user)
    Application.put_env(:bitblocks, :rpc_password, @rpc_password)
    Application.put_env(:bitblocks, :rpc_url, @node_url)
    System.put_env("OPS_TEST_ENV_SECRET", @env_secret)
    :persistent_term.erase({Ops, :node_report})

    on_exit(fn ->
      System.delete_env("OPS_TEST_ENV_SECRET")
      :persistent_term.erase({Ops, :node_report})

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:bitblocks, key)
        {key, value} -> Application.put_env(:bitblocks, key, value)
      end)
    end)

    {:ok, _key, token} = ApiKeys.create("ops-session", 1_000, scopes: ["ops_read"])
    {:ok, _key, plain} = ApiKeys.create("existing-tenant", 1_000)
    %{token: token, plain: plain}
  end

  defp with_key(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp block!(height, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Block{
          height: height,
          hash: String.pad_leading("#{height}", 64, "0"),
          sync_state: "header_synced",
          num_tx: 2
        },
        attrs
      )
    )
  end

  defp assert_clean(body) do
    text = Jason.encode!(body)
    for leak <- @leaks, do: refute(text =~ leak, "#{inspect(leak)} leaked in #{text}")
  end

  describe "who gets in" do
    @paths ["/api/v1/ops/sync", "/api/v1/ops/node", "/api/v1/ops/errors", "/api/v1/ops/blocks/1"]

    test "no key is a 401", %{conn: conn} do
      for path <- @paths do
        assert %{"error" => _} = conn |> get(path) |> json_response(401)
      end

      assert conn |> post("/api/v1/ops/mcp", %{}) |> response(401)
    end

    test "a key without the scope is a 403", %{conn: conn, plain: plain} do
      for path <- @paths do
        assert %{"error" => error} = conn |> with_key(plain) |> get(path) |> json_response(403)
        assert error =~ "ops_read"
      end

      assert conn |> with_key(plain) |> post("/api/v1/ops/mcp", %{}) |> response(403)
    end

    test "an existing key gains the scope only by a grant", %{conn: conn} do
      {:ok, key, token} = ApiKeys.create("older", 100)
      assert key.scopes == []
      assert conn |> with_key(token) |> get("/api/v1/ops/sync") |> response(403)

      assert {:ok, %{scopes: ["ops_read"]}} = ApiKeys.grant_scope(key.id, "ops_read")
      assert conn |> with_key(token) |> get("/api/v1/ops/sync") |> response(200)
    end

    test "a scope nobody defined can't be granted" do
      {:ok, key, _} = ApiKeys.create("older", 100)
      assert {:error, %Ecto.Changeset{}} = ApiKeys.grant_scope(key.id, "ops_write")
      assert {:error, %Ecto.Changeset{}} = ApiKeys.create("x", 100, scopes: ["admin"])
    end

    test "create_from_hash takes the scope too", %{conn: conn} do
      token = "bbk_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      assert {:ok, _} = ApiKeys.create_from_hash("hashed", 100, hash, scopes: ["ops_read"])
      assert conn |> with_key(token) |> get("/api/v1/ops/sync") |> response(200)
    end

    test "a revoked key is refused", %{conn: conn} do
      {:ok, key, token} = ApiKeys.create("gone", 100, scopes: ["ops_read"])
      ApiKeys.revoke(key.id)
      assert conn |> with_key(token) |> get("/api/v1/ops/sync") |> response(401)
    end

    test "a signed-in session is not a key", %{conn: conn} do
      conn = conn |> init_test_session(%{"user_id" => 1}) |> get("/api/v1/ops/sync")
      assert response(conn, 401)
    end

    test "answers are never cached", %{conn: conn, token: token} do
      conn = conn |> with_key(token) |> get("/api/v1/ops/sync")
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end

  describe "GET /api/v1/ops/sync" do
    test "answers the leader, slots, each block's stage and failed blocks, scrubbed",
         %{conn: conn, token: token} do
      block!(7, %{sync_state: "failed", tx_sync_attempts: 3, tx_sync_error: @planted_error})

      body = conn |> with_key(token) |> get("/api/v1/ops/sync") |> json_response(200)

      assert Map.has_key?(body, "leader")
      assert Map.has_key?(body, "concurrency")
      assert is_list(body["blocks"])
      assert [%{"height" => 7, "attempts" => 3, "error" => error}] = body["failed"]
      assert error =~ "econnrefused at [url] via [host] for [address]"
      assert_clean(body)
    end

    test "shows a table row by its job, with the node as an id" do
      snapshot = %{
        SyncProgress.empty_snapshot()
        | sync: %{
            leader: :"bitblocks@10.20.30.40",
            paused: false,
            tip: 10,
            complete_through: 6,
            target: 7,
            concurrency: 2,
            max_concurrency: 4,
            limit_reason: "node RPC threads",
            in_use: 1,
            rows: [
              %{
                hash: "abc",
                height: 7,
                num_tx: 2,
                fetched: 1,
                sync_state: "txs_syncing",
                failures: 2,
                error: @planted_error,
                slot: 1,
                node: "bitblocks@10.20.30.40",
                job_state: "executing",
                next_retry_at: false
              }
            ]
          }
      }

      live = Ops.sync_live(snapshot, [])

      assert live.leader == Ops.node_id("bitblocks@10.20.30.40")
      assert [row] = live.blocks
      assert %{height: 7, stage: "txs_syncing", failures: 2, slot: 1, fetched: 1} = row
      assert row.node == live.leader
      assert row.next_retry_at == nil
      assert_clean(live)
    end
  end

  describe "GET /api/v1/ops/blocks/:height" do
    test "tells one block's story", %{conn: conn, token: token} do
      block = block!(5, %{sync_state: "completed", size: 1_000, tx_sync_error: @planted_error})

      for n <- 1..2 do
        Repo.insert!(%Transaction{
          txid: String.pad_leading("#{n}", 64, "a"),
          block_hash: block.hash,
          block_height: 5
        })
      end

      Repo.insert!(%Reorg{
        detected_at: DateTime.utc_now() |> DateTime.truncate(:second),
        last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second),
        fork_height: 6,
        fork_point: 4,
        orphan_count: 2,
        outcome: "resolved",
        summary: "A two-block reorg."
      })

      send(
        Process.whereis(SyncProgress),
        {:sync_fetch,
         %{source: :rest, bytes: 1_000, ms: 12, height: 5, at: System.system_time(:second)}}
      )

      SyncProgress.flush()

      body = conn |> with_key(token) |> get("/api/v1/ops/blocks/5") |> json_response(200)

      assert body["hash"] == block.hash
      assert body["num_tx"] == 2
      assert body["stored_txs"] == 2
      assert body["sync_state"] == "completed"
      assert %{"source" => "rest", "bytes" => 1_000, "ms" => 12} = body["last_fetch"]
      assert [%{"fork_height" => 6, "summary" => "A two-block reorg."}] = body["reorgs"]
      assert_clean(body)
    end

    test "says when no block is stored, or the height isn't one", %{conn: conn, token: token} do
      assert conn |> with_key(token) |> get("/api/v1/ops/blocks/99") |> json_response(404)
      assert conn |> with_key(token) |> get("/api/v1/ops/blocks/abc") |> json_response(400)
      assert conn |> with_key(token) |> get("/api/v1/ops/blocks/-1") |> json_response(400)
    end
  end

  describe "GET /api/v1/ops/node" do
    test "answers height, headers, latency and load", %{conn: conn, token: token} do
      Application.put_env(:bitblocks, :bitcoinsv_cli, UpNode)

      body = conn |> with_key(token) |> get("/api/v1/ops/node") |> json_response(200)

      assert %{"state" => "ok", "blocks" => 900, "headers" => 901} = body
      assert %{"ok" => true, "error" => nil, "ms" => ms} = body["rpc"]
      assert is_integer(ms)
      assert %{"ok" => true, "error" => nil} = body["rest"]
      assert Map.has_key?(body["load"], "blocks_per_minute")
      assert_clean(body)
    end

    test "a node that's down says so, and its error carries no address",
         %{conn: conn, token: token} do
      Application.put_env(:bitblocks, :bitcoinsv_cli, DownNode)

      body = conn |> with_key(token) |> get("/api/v1/ops/node") |> json_response(200)

      assert body["state"] == "unreachable"
      assert %{"ok" => false, "error" => error} = body["rpc"]
      assert error =~ "econnrefused"
      assert %{"ok" => false, "error" => rest_error} = body["rest"]
      assert rest_error =~ "no route"
      assert_clean(body)
    end

    test "a second call within the window asks the node nothing new" do
      Application.put_env(:bitblocks, :bitcoinsv_cli, UpNode)
      first = Ops.node_report()
      Application.put_env(:bitblocks, :bitcoinsv_cli, DownNode)
      assert Ops.node_report() == first
    end
  end

  describe "GET /api/v1/ops/errors" do
    test "answers recent error lines, newest first and scrubbed", %{conn: conn, token: token} do
      capture_log(fn ->
        Logger.error("first #{@planted_error}", ip: "203.0.113.9")
        Logger.error("second ops error line")
        Logger.warning("a warning is not an error")
      end)

      body = conn |> with_key(token) |> get("/api/v1/ops/errors?limit=2") |> json_response(200)

      assert [%{"message" => "second ops error line", "level" => "error"}, older] = body["errors"]
      assert older["message"] =~ "first econnrefused at [url]"
      assert body["kept"] == ErrorLog.capacity()
      refute Jason.encode!(body) =~ "203.0.113.9"
      assert_clean(body)
    end

    test "keeps a bounded number of lines" do
      capture_log(fn ->
        for n <- 1..(ErrorLog.capacity() + 5), do: Logger.error("bounded line #{n}")
      end)

      assert length(ErrorLog.recent(1_000)) <= ErrorLog.capacity()
      assert Ops.errors(100_000).errors |> length() <= ErrorLog.capacity()
    end

    test "a report that can't be formatted doesn't take the handler down" do
      capture_log(fn -> Logger.error(%{some: :report, at: @private_ip}) end)
      assert :bitblocks_ops_error_log in :logger.get_handler_ids()
    end
  end

  describe "POST /api/v1/ops/mcp" do
    defp mcp(conn, token, method, params \\ %{}, id \\ 1) do
      conn
      |> with_key(token)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/v1/ops/mcp",
        Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})
      )
    end

    test "initializes and lists the four read tools", %{conn: conn, token: token} do
      result =
        mcp(conn, token, "initialize", %{protocolVersion: "2025-03-26"})
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["protocolVersion"] == "2025-03-26"
      assert result["serverInfo"]["name"] == "bitblocks-ops"
      assert Map.has_key?(result["capabilities"], "tools")

      tools = mcp(conn, token, "tools/list") |> json_response(200) |> get_in(["result", "tools"])
      assert Enum.map(tools, & &1["name"]) == ["sync_live", "block", "node", "errors"]
    end

    test "a notification gets no answer", %{conn: conn, token: token} do
      conn =
        conn
        |> with_key(token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/ops/mcp", ~s({"jsonrpc":"2.0","method":"notifications/initialized"}))

      assert response(conn, 202) == ""
    end

    test "each tool returns the same map as its Ops function", %{conn: conn, token: token} do
      Application.put_env(:bitblocks, :bitcoinsv_cli, UpNode)
      block!(5)

      for {tool, args, expected} <- [
            {"sync_live", %{}, Ops.sync_live()},
            {"block", %{height: 5}, Ops.block(5)},
            {"node", %{}, Ops.node_report()},
            {"errors", %{limit: 1}, Ops.errors(1)}
          ] do
        result =
          mcp(conn, token, "tools/call", %{name: tool, arguments: args})
          |> json_response(200)
          |> Map.fetch!("result")

        assert result["isError"] == false
        expected = expected |> Jason.encode!() |> Jason.decode!()
        assert result["structuredContent"] == expected
        assert result["content"] |> hd() |> Map.fetch!("text") |> Jason.decode!() == expected
      end
    end

    test "there are no write tools, and unknown things are errors", %{conn: conn, token: token} do
      assert %{"error" => %{"code" => -32_602}} =
               mcp(conn, token, "tools/call", %{name: "set_concurrency", arguments: %{n: 9}})
               |> json_response(200)

      assert %{"error" => %{"code" => -32_601}} =
               mcp(conn, token, "resources/list") |> json_response(200)

      assert %{"result" => %{"isError" => true}} =
               mcp(conn, token, "tools/call", %{name: "block", arguments: %{height: 404}})
               |> json_response(200)
    end

    test "there is no stream to open", %{conn: conn, token: token} do
      assert conn |> with_key(token) |> get("/api/v1/ops/mcp") |> response(405)
    end
  end
end
