defmodule Bitblocks.ReleaseScriptAnalysisTest do
  # The script analysis backfill (docs/DERIVED_DATA.md): picks txs below the
  # script_analysis step's version in a height range, stamps them, records
  # every run (dry runs too), and a rerun finds nothing.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{RawBlock, Transaction, TxIngest, TxPipeline}
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Release

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  defp quietly(fun) do
    output = capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    {result, output}
  end

  setup do
    {in_range, _} = a = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
    {outside, _} = b = tx([funding_outpoint()], [p2pkh(address(), 2_000)])
    {current, _} = c = tx([funding_outpoint()], [p2pkh(address(), 3_000)])

    :ok = TxIngest.store(tx_json(a), block_fixture(%{height: 50}))
    :ok = TxIngest.store(tx_json(c), block_fixture(%{height: 51}))
    :ok = TxIngest.store(tx_json(b), block_fixture(%{height: 60}))

    Repo.update_all(from(t in Transaction, where: t.txid in ^[in_range, outside]),
      set: [script_analysis_version: nil, output_types: nil]
    )

    %{in_range: in_range, outside: outside, current: current}
  end

  test "a dry run writes nothing and records a run", ctx do
    {report, output} = quietly(fn -> Release.backfill_script_analysis(0, 55) end)

    assert %{applied: false, outcome: "ok", rows_examined: 1, rows_below_version: 1} = report
    assert output =~ "DRY RUN (nothing written): script analysis 0..55"
    assert Chain.get_transaction!(ctx.in_range).script_analysis_version == nil

    assert %Run{derivation: "script_analysis", applied: false, rows_below_version: 1} =
             Repo.get!(Run, report.run_id)
  end

  test "apply stamps only rows below the version in the range; a rerun finds nothing", ctx do
    {report, _} = quietly(fn -> Release.backfill_script_analysis(0, 55, apply: true) end)
    assert %{outcome: "ok", rows_changed: 1, rows_below_version: 0} = report

    tx = Chain.get_transaction!(ctx.in_range)
    assert tx.script_analysis_version == TxPipeline.version(:script_analysis)
    assert tx.output_types == %{"p2pkh" => 1}

    assert Chain.get_transaction!(ctx.outside).script_analysis_version == nil

    {rerun, output} = quietly(fn -> Release.backfill_script_analysis(0, 55) end)
    assert %{rows_examined: 0, rows_changed: 0, rows_below_version: 0} = rerun
    assert output =~ "0 transaction(s) below the version in the range"
  end

  test "a small block batch still covers the range", ctx do
    {report, _} =
      quietly(fn ->
        Release.backfill_script_analysis(0, 100, apply: true, block_batch: 1, batch_size: 1)
      end)

    assert %{rows_changed: 2, rows_below_version: 0} = report
    assert Chain.get_transaction!(ctx.outside).script_analysis_version != nil
  end

  test "a row with no block_height is found through its block, and gets its height", ctx do
    Repo.update_all(from(t in Transaction, where: t.txid == ^ctx.in_range),
      set: [block_height: nil]
    )

    {dry, _} = quietly(fn -> Release.backfill_script_analysis(0, 55) end)
    assert %{rows_examined: 1, rows_below_version: 1} = dry

    {report, _} = quietly(fn -> Release.backfill_script_analysis(0, 55, apply: true) end)
    assert %{rows_changed: 1, rows_below_version: 0} = report

    tx = Chain.get_transaction!(ctx.in_range)
    assert tx.block_height == 50
    assert tx.script_analysis_version == TxPipeline.version(:script_analysis)
  end
end
