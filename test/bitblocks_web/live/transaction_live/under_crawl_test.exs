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
end
