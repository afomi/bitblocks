defmodule Bitblocks.ReleaseTxStepsTest do
  # The tx steps backfill (docs/DERIVED_DATA.md): a stored row the sync
  # skipped never recorded its spends. This finds it through its block, runs
  # the steps, and a rerun finds nothing.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{RawBlock, Spend, Transaction, TxIngest}
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Release

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  defp quietly(fun) do
    output = capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    {result, output}
  end

  defp spends(txid), do: Repo.all(from(s in Spend, where: s.spending_txid == ^txid))

  setup do
    {skipped, _} = a = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
    {kept, _} = b = tx([funding_outpoint()], [p2pkh(address(), 2_000)])

    :ok = TxIngest.store(tx_json(a), block_fixture(%{height: 70, sync_state: "completed"}))
    :ok = TxIngest.store(tx_json(b), block_fixture(%{height: 71, sync_state: "completed"}))

    Repo.delete_all(from(s in Spend, where: s.spending_txid == ^skipped))

    Repo.update_all(from(t in Transaction, where: t.txid == ^skipped), set: [block_height: nil])

    %{skipped: skipped, kept: kept}
  end

  test "a dry run counts what it would run, writes nothing, and records a run", ctx do
    {report, output} = quietly(fn -> Release.backfill_tx_steps(0, 100) end)

    assert %{applied: false, outcome: "ok", rows_changed: 1, rows_below_version: 1} = report
    assert output =~ "DRY RUN (nothing written)"
    assert spends(ctx.skipped) == []
    assert %Run{derivation: "tx_steps", applied: false} = Repo.get!(Run, report.run_id)
  end

  test "apply records the spends of a row with no height; a rerun finds nothing", ctx do
    {report, _} = quietly(fn -> Release.backfill_tx_steps(0, 100, apply: true, tx_batch: 1) end)

    assert %{outcome: "ok", blocks_examined: 2, rows_changed: 1, rows_below_version: 0} = report
    assert [%Spend{spending_vin: 0}] = spends(ctx.skipped)

    {rerun, _} = quietly(fn -> Release.backfill_tx_steps(0, 100) end)
    assert %{rows_changed: 0, rows_below_version: 0} = rerun
  end

  test "a row not yet analysed is left and counted, so the run says it isn't finished", ctx do
    Repo.update_all(from(t in Transaction, where: t.txid == ^ctx.skipped),
      set: [script_analysis_version: nil, coinbase: nil]
    )

    {report, output} = quietly(fn -> Release.backfill_tx_steps(0, 100, apply: true) end)

    assert %{rows_changed: 0, rows_below_version: 1, details: %{not_analysed: 1}} = report
    assert output =~ "NOT ANALYSED"
    assert spends(ctx.skipped) == []
  end

  test "a flagged coinbase is no missing spend", ctx do
    Repo.update_all(from(t in Transaction, where: t.txid == ^ctx.skipped), set: [coinbase: true])

    {report, _} = quietly(fn -> Release.backfill_tx_steps(0, 100) end)
    assert %{rows_changed: 0, rows_below_version: 0} = report
    assert Chain.get_transaction!(ctx.skipped).coinbase
  end

  describe "a block larger than the id window (#89)" do
    setup do
      block = block_fixture(%{height: 80, sync_state: "completed"})

      txids =
        for sats <- 1..5 do
          {txid, _} = t = tx([funding_outpoint()], [p2pkh(address(), 1_000 + sats)])
          :ok = TxIngest.store(tx_json(t), block)
          txid
        end

      [kept, unanalysed | skipped] = txids
      Repo.delete_all(from(s in Spend, where: s.spending_txid in ^[unanalysed | skipped]))

      Repo.update_all(from(t in Transaction, where: t.txid == ^unanalysed),
        set: [script_analysis_version: nil]
      )

      %{block: block, kept: kept, unanalysed: unanalysed, skipped3: skipped}
    end

    test "every window is walked: the analysed rows run, the rest are counted", ctx do
      {report, _} =
        quietly(fn ->
          Release.backfill_tx_steps(80, 80, apply: true, id_window: 2, tx_batch: 2)
        end)

      assert %{rows_changed: 3, rows_below_version: 1, details: %{not_analysed: 1}} = report
      for txid <- ctx.skipped3, do: assert([%Spend{}] = spends(txid))
      assert spends(ctx.unanalysed) == []
    end

    test "the spend probe never spans the block: by primary key, an id window at a time" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "tx-steps-#{inspect(ref)}",
        [:bitblocks, :repo, :query],
        fn _event, _measure, meta, _ -> send(parent, {ref, meta.query, meta.params}) end,
        nil
      )

      try do
        quietly(fn -> Release.backfill_tx_steps(80, 80, id_window: 2) end)
      after
        :telemetry.detach("tx-steps-#{inspect(ref)}")
      end

      probes = collect_probes(ref, [])
      assert length(probes) == 3

      for {query, params} <- probes do
        refute query =~ "block_hash"
        assert [ids] = Enum.filter(params, &is_list/1)
        assert length(ids) <= 2
      end
    end
  end

  # https://github.com/afomi/bitblocks/issues/115
  describe "a dense block split into sub-batches" do
    alias Bitblocks.Chain.TxPipeline.TxStepsBackfill

    setup do
      block = block_fixture(%{height: 85, sync_state: "completed"})

      txids =
        for sats <- 1..12 do
          {txid, _} = t = tx([funding_outpoint()], [p2pkh(address(), 5_000 + sats)])
          :ok = TxIngest.store(tx_json(t), block)
          txid
        end

      Repo.delete_all(from(s in Spend, where: s.spending_txid in ^txids))

      ids =
        Repo.all(
          from(t in Transaction, where: t.txid in ^txids, order_by: t.id, select: {t.id, t.txid})
        )

      %{ids: ids}
    end

    # A fake clock the database moves: every query this process runs costs
    # 10 ms, so a slow, dense block runs in no real time.
    defp query_clock do
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      me = self()
      id = "tx-steps-clock-#{inspect(make_ref())}"

      :telemetry.attach(
        id,
        [:bitblocks, :repo, :query],
        fn _event, _measure, _meta, _ ->
          if self() == me, do: Agent.update(clock, &(&1 + 10))
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
      fn -> Agent.get(clock, & &1) end
    end

    # Each batch's cursor and its time by the clock.
    defp run_logged(opts) do
      now = query_clock()
      {:ok, log} = Agent.start_link(fn -> [] end)

      after_batch = fn cursor, _report ->
        Agent.update(log, &[{cursor, now.()} | &1])
        :cont
      end

      report =
        TxStepsBackfill.run(
          85,
          85,
          Keyword.merge(
            [apply: true, tx_batch: 1, pause_ms: 0, clock: now, after_batch: after_batch],
            opts
          )
        )

      batches = log |> Agent.get(& &1) |> Enum.reverse()
      {report, batches}
    end

    defp spend_count(txid),
      do: Repo.aggregate(from(s in Spend, where: s.spending_txid == ^txid), :count)

    test "the batch time stays under the cap; every tx runs once, and the block counts once",
         %{ids: ids} do
      # One tx costs about 100 ms by this clock. Pages start at 4 txs (about
      # 400 ms, over the 150 ms page target), so they shrink to one.
      {report, batches} = run_logged(tx_batch: 4, page_ms: 150, batch_ms: 300)

      assert %{outcome: "ok", rows_changed: 12, rows_below_version: 0, blocks_examined: 1} =
               report

      for {_id, txid} <- ids, do: assert(spend_count(txid) == 1)

      # Split inside the block: each sub-batch ended on a tx of the block.
      {within, [{{85, _block_id}, _}]} = Enum.split(batches, -1)
      assert length(within) >= 3

      for {{:within, 85, after_tx}, _} <- within,
          do: assert(List.keymember?(ids, after_tx, 0))

      # Each batch's time by the clock: the first runs its first page whole
      # (4 txs); once pages shrink, each is the cap plus at most one tx.
      [first | rest] =
        batches
        |> Enum.map(&elem(&1, 1))
        |> then(&Enum.zip([0 | &1], &1))
        |> Enum.map(fn {from, to} -> to - from end)

      assert first <= 300 + 4 * 150
      assert Enum.all?(rest, &(&1 <= 300 + 150))
    end

    test "a resume inside the block runs only the txs after the checkpoint", %{ids: ids} do
      {done, rest} = Enum.split(ids, 6)
      {last_done, _} = List.last(done)

      {report, _} = run_logged(resume_after_tx: last_done)

      assert %{outcome: "ok", rows_changed: 6, blocks_examined: 0} = report
      for {_id, txid} <- done, do: assert(spend_count(txid) == 0)
      for {_id, txid} <- rest, do: assert(spend_count(txid) == 1)
    end
  end

  defp collect_probes(ref, acc) do
    receive do
      {^ref, query, params} ->
        acc = if query =~ ~s("spend_index"), do: [{query, params} | acc], else: acc
        collect_probes(ref, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
