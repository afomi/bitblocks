defmodule BitblocksWeb.TransactionLive.UnderCrawlTest do
  # A distributed crawl of transaction pages filled the database pool
  # (2026-11-22). These pin what a transaction page may ask of it.
  # The sync snapshot and the Position config are VM-global.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures, only: [tx: 2, p2pkh: 2, address: 0, funding_outpoint: 0]

  alias Bitblocks.SyncProgress
  alias Bitblocks.Sync.Position
  alias BitblocksWeb.TransactionLive.PageCache

  setup do
    previous = Application.get_env(:bitblocks, Position)
    Application.put_env(:bitblocks, Position, source: :memory)
    Position.reset()

    on_exit(fn ->
      Application.put_env(:bitblocks, Position, previous)
      Position.reset()
      :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()})
    end)

    :ok
  end

  defp seed_snapshot(tip, complete_through) do
    empty = SyncProgress.empty_snapshot()

    :ets.insert(
      SyncProgress,
      {:snapshot,
       %{
         empty
         | updated_at: DateTime.utc_now(),
           overview: %{empty.overview | our_tip: tip, complete_through: complete_through}
       }}
    )
  end

  defp store_tx(height) do
    {txid, hex} = tx([funding_outpoint()], [p2pkh(address(), 1_234)])
    json = Bitblocks.Chain.RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))
    :ok = Bitblocks.Chain.TxIngest.store(json, block_fixture(%{height: height}))
    txid
  end

  defp queries(fun) do
    parent = self()
    ref = make_ref()
    handler = "under-crawl-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:bitblocks, :repo, :query],
      fn _, _, meta, _ -> send(parent, {ref, meta.query}) end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(ref, acc) do
    receive do
      {^ref, sql} -> drain(ref, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Our tip and complete_through: max(height), ORDER BY height DESC LIMIT 1,
  # and the count(*) and gap search of Sync.complete_through/1.
  defp tip_or_coverage?(sql) do
    sql =~ ~r/max\(b\d+\."height"\)/i or
      sql =~ ~r/FROM "blocks" AS b\d+ ORDER BY b\d+\."height" DESC/ or
      sql =~ ~r/count\(\*\) FROM "blocks"/i or
      sql =~ "NOT EXISTS (SELECT 1 FROM blocks n WHERE n.height = b.height + 1)" or
      sql =~ "CROSS JOIN LATERAL"
  end

  describe "tip and coverage" do
    test "a transaction page asks the database for neither, on render or connect",
         %{conn: conn} do
      txid = store_tx(10)
      seed_snapshot(10, 10)

      {{:ok, view, html}, sqls} = queries(fn -> live(conn, ~p"/transactions/#{txid}") end)

      assert html =~ txid
      assert render(view) =~ txid
      assert sqls != []
      assert Enum.reject(sqls, &tip_or_coverage?/1) == sqls
    end

    test "the page states spent-ness from the snapshot's coverage", %{conn: conn} do
      txid = store_tx(10)

      # The snapshot says the index reaches the tip: an output with no
      # stored spend is unspent.
      seed_snapshot(10, 10)
      {:ok, _view, html} = live(conn, ~p"/transactions/#{txid}")
      assert html =~ "Unspent"
    end
  end

  describe "the page cache" do
    setup do
      previous = Application.get_env(:bitblocks, PageCache)
      Application.put_env(:bitblocks, PageCache, enabled: true)
      PageCache.clear()

      on_exit(fn ->
        Application.put_env(:bitblocks, PageCache, previous)
        PageCache.clear()
      end)

      :ok
    end

    # A tx at height 10 under a tip of 200 is 190 blocks deep. The banner's
    # block is 10, stored, so its time is read once and remembered.
    defp deep_tx do
      txid = store_tx(10)
      seed_snapshot(200, 10)
      txid
    end

    defp warm(conn, txid) do
      first = get(conn, ~p"/transactions/#{txid}")
      assert first.status == 200
      # put/2 is a cast; stats/0 is a call behind it.
      assert PageCache.stats().entries == 1
      first
    end

    test "a deep tx's repeat view asks nothing of the database", %{conn: conn} do
      txid = deep_tx()
      first = warm(conn, txid)

      {second, sqls} = queries(fn -> get(build_conn(), ~p"/transactions/#{txid}") end)

      assert second.status == 200
      assert sqls == []
      assert html_response(second, 200) =~ txid
      # The same page, apart from the per-request tokens.
      assert strip_tokens(second.resp_body) == strip_tokens(first.resp_body)
    end

    test "a LiveView connecting to a kept page asks nothing either", %{conn: conn} do
      txid = deep_tx()
      warm(conn, txid)

      {{:ok, view, _html}, sqls} =
        queries(fn -> live(build_conn(), ~p"/transactions/#{txid}") end)

      assert sqls == []
      assert render(view) =~ txid
    end

    test "a signed-out view of a deep tx may be kept by the browser", %{conn: conn} do
      txid = deep_tx()

      first = warm(conn, txid)
      second = get(build_conn(), ~p"/transactions/#{txid}")

      for conn <- [first, second] do
        assert get_resp_header(conn, "cache-control") == ["private, max-age=600"]
      end
    end

    test "a signed-in view keeps Phoenix's no-store default", %{conn: conn} do
      txid = deep_tx()
      warm(conn, txid)

      user = Bitblocks.Repo.insert!(%Bitblocks.Accounts.User{github_id: 4_242, login: "viewer"})

      signed_in =
        build_conn()
        |> init_test_session(%{"user_id" => user.id})
        |> get(~p"/transactions/#{txid}")

      assert signed_in.status == 200
      refute get_resp_header(signed_in, "cache-control") == ["private, max-age=600"]
    end

    test "a tx near the tip is not kept", %{conn: conn} do
      txid = store_tx(10)
      # 40 blocks deep: under the 100 the cache asks for.
      seed_snapshot(50, 10)

      conn = get(conn, ~p"/transactions/#{txid}")

      assert conn.status == 200
      assert PageCache.stats().entries == 0
      assert get_resp_header(conn, "cache-control") == ["max-age=0, private, must-revalidate"]
    end

    test "with every pool connection held, a kept page still renders", %{conn: conn} do
      txid = deep_tx()
      warm(conn, txid)
      parent = self()

      holder =
        spawn(fn ->
          Bitblocks.Repo.transaction(fn ->
            send(parent, :held)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :held
      watch = Process.monitor(holder)

      conn = get(build_conn(), ~p"/transactions/#{txid}")

      send(holder, :release)
      assert_receive {:DOWN, ^watch, _, _, _}
      assert html_response(conn, 200) =~ txid
    end
  end

  defp strip_tokens(html) do
    html
    |> String.replace(~r/content="[^"]*" name="csrf-token"|name="csrf-token" content="[^"]*"/, "")
    |> String.replace(~r/data-phx-session="[^"]*"/, "")
    |> String.replace(~r/data-phx-static="[^"]*"/, "")
    |> String.replace(~r/id="phx-[^"]*"/, "")
  end
end
