defmodule BitblocksWeb.Plugs.PoolGuardTest do
  # The pool gauge is VM-global, and one test holds the sandbox connection.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures, only: [tx: 2, p2pkh: 2, address: 0, funding_outpoint: 0]

  alias Bitblocks.Repo
  alias Bitblocks.Repo.PoolMonitor

  setup do
    on_exit(fn -> PoolMonitor.record(0) end)
    :ok
  end

  defp stored_txid do
    {txid, hex} = tx([funding_outpoint()], [p2pkh(address(), 1_234)])
    json = Bitblocks.Chain.RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))
    :ok = Bitblocks.Chain.TxIngest.store(json, block_fixture(%{height: 10}))
    txid
  end

  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler = "pool-guard-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:bitblocks, :repo, :query],
      fn _, _, _, _ -> send(parent, {ref, :query}) end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {result, drain(ref, 0)}
  end

  defp drain(ref, n) do
    receive do
      {^ref, :query} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  describe "while the pool's queue is long" do
    test "a page is a 503 with Retry-After at once, and asks nothing of the pool", %{conn: conn} do
      txid = stored_txid()
      PoolMonitor.record(1_000)

      {conn, queries} = count_queries(fn -> get(conn, ~p"/transactions/#{txid}") end)

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["10"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert conn.resp_body =~ "Try again"
      assert queries == 0
    end

    test "an API caller gets the same 503 as JSON", %{conn: conn} do
      PoolMonitor.record(1_000)

      conn = get(conn, "/api/v1/blocks")

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["10"]
      assert %{"error" => "busy", "retry_after_s" => 10} = json_response(conn, 503)
    end

    test "the deploy check and a signed-in operator still get through", %{conn: conn} do
      PoolMonitor.record(1_000)

      refute get(conn, "/api/v1/status").status == 503

      signed_in = init_test_session(build_conn(), %{"user_id" => -1})
      refute get(signed_in, "/blocks").status == 503
    end

    test "a queue under the limit sheds nothing", %{conn: conn} do
      PoolMonitor.record(39)
      assert get(conn, "/blocks").status == 200
    end

    test "queue_length: 0 turns shedding off", %{conn: conn} do
      previous = Application.get_env(:bitblocks, BitblocksWeb.Plugs.PoolGuard)
      Application.put_env(:bitblocks, BitblocksWeb.Plugs.PoolGuard, queue_length: 0)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:bitblocks, BitblocksWeb.Plugs.PoolGuard, previous),
          else: Application.delete_env(:bitblocks, BitblocksWeb.Plugs.PoolGuard)
      end)

      PoolMonitor.record(1_000)
      assert get(conn, "/blocks").status == 200
    end
  end

  describe "with every pool connection held" do
    # The sandbox gives this test one connection. A process holding it in a
    # transaction leaves the page's checkout queued until the pool drops it,
    # as production's pool did under the crawl.
    test "a transaction page is a 503 with Retry-After within seconds, not a 500",
         %{conn: conn} do
      txid = stored_txid()
      parent = self()

      holder =
        spawn(fn ->
          Repo.transaction(fn ->
            send(parent, :held)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :held
      watch = Process.monitor(holder)

      started = System.monotonic_time(:millisecond)

      {status, headers, _body} =
        assert_error_sent(503, fn -> get(conn, ~p"/transactions/#{txid}") end)

      elapsed = System.monotonic_time(:millisecond) - started
      send(holder, :release)
      assert_receive {:DOWN, ^watch, _, _, _}

      assert status == 503
      assert {"retry-after", "10"} in headers
      assert elapsed < 5_000
    end
  end
end
