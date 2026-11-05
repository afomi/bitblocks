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
end
