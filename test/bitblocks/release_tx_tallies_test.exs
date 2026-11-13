defmodule Bitblocks.ReleaseTxTalliesTest do
  # The tallies backfill (docs/DERIVED_DATA.md): picks rows below the current
  # tallies_version and stamps them, a rerun finds nothing, a dry run writes
  # only its run record, and a failing batch records `partial` with the error
  # and keeps the batches before it.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, RawBlock, Transaction, TxIngest, TxPipeline}
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Release

  @fifty_btc 5_000_000_000

  # A tally step that raises on block 21: a batch that fails mid-run.
  defmodule RaisesAt21 do
    def name, do: "raises_at_21"
    def stage, do: :chunk
    def version, do: 1
    def run_chunk(_attrs, %{height: 21}), do: raise("boom at block 21")
    def run_chunk(attrs, _block), do: attrs
  end

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  defp quietly(fun) do
    capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  # Two completed blocks stored as the ingest did before the tally steps and
  # their versions: the tally columns, the totals and the stamps empty.
  setup do
    a = block_fixture(%{height: 20, sync_state: "completed"})
    b = block_fixture(%{height: 21, sync_state: "completed"})
    pending = block_fixture(%{height: 22, sync_state: "header_only"})

    {parent_txid, _} = parent = tx([funding_outpoint()], [p2pkh(address(), 10_000)])
    {child_txid, _} = child = tx(["#{parent_txid}_0"], [p2pkh(address(), 9_000)])
    burn = %BSV.TxOut{satoshis: 100, script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "x"]}}
    {burn_txid, _} = burner = tx(["#{child_txid}_0"], [p2pkh(address(), 8_000), burn])
    {later_txid, _} = later = tx(["#{burn_txid}_0"], [p2pkh(address(), 7_000)])

    :ok = TxIngest.store(tx_json(parent), a)
    [_, _] = TxIngest.store_chunk([tx_json(child), tx_json(burner)], b)
    :ok = TxIngest.store(tx_json(later), pending)

    Repo.update_all(Transaction,
      set: [
        total_input_satoshis: nil,
        total_output_satoshis: nil,
        fee_satoshis: nil,
        burned_satoshis: nil,
        tallies_version: nil
      ]
    )

    Repo.update_all(Block,
      set: [
        sats_out: nil,
        fees: nil,
        miner_reward: nil,
        subsidy: nil,
        burned: nil,
        fees_verified: nil,
        tallies_version: nil
      ]
    )

    %{
      a: a,
      b: b,
      parent: parent_txid,
      child: child_txid,
      burner: burn_txid,
      later: later_txid
    }
  end

  test "a dry run counts what it would stamp, writes nothing, and records a run", ctx do
    output = capture_io(fn -> send(self(), {:report, Release.backfill_tx_tallies(0, 100)}) end)
    assert_received {:report, report}

    assert %{
             applied: false,
             outcome: "ok",
             blocks_examined: 2,
             rows_examined: 3,
             rows_changed: 3,
             rows_below_version: 3,
             details: %{
               values_changed: 3,
               sats_in_unknown: 1,
               blocks_changed: 2,
               blocks_below_version: 2,
               unverified: []
             }
           } = report

    assert output =~ "DRY RUN (nothing written)"
    assert output =~ "3 transaction(s) to stamp v#{TxPipeline.version(:tallies)}"
    assert output =~ "3 transaction(s) and 2 block(s) below the version in the range"
    assert output =~ "Run again with apply: true"

    assert Chain.get_transaction!(ctx.child).total_input_satoshis == nil
    assert Chain.get_transaction!(ctx.child).tallies_version == nil
    assert Repo.reload!(ctx.b).sats_out == nil

    assert %Run{
             derivation: "tallies",
             applied: false,
             outcome: "ok",
             from_height: 0,
             to_height: 100,
             rows_examined: 3,
             rows_changed: 3,
             rows_below_version: 3,
             command: "Release.backfill_tx_tallies(0, 100)",
             finished_at: %DateTime{}
           } = run = Repo.get!(Run, report.run_id)

    assert run.version == TxPipeline.version(:tallies)
  end

  test "apply stamps the tallies and block totals; a rerun finds nothing", ctx do
    report = quietly(fn -> Release.backfill_tx_tallies(0, 100, apply: true, tx_batch: 1) end)
    assert %{outcome: "ok", rows_changed: 3, rows_below_version: 0} = report

    # No coinbase stored in these fixture blocks: written, and not final.
    assert %{blocks_below_version: 2, reward_unknown: 2} = report.details

    version = TxPipeline.version(:tallies)

    assert %{total_input_satoshis: nil, total_output_satoshis: 10_000, fee_satoshis: nil} =
             Chain.get_transaction!(ctx.parent)

    assert %{
             total_input_satoshis: 10_000,
             total_output_satoshis: 9_000,
             fee_satoshis: 1_000,
             tallies_version: ^version
           } = Chain.get_transaction!(ctx.child)

    assert %{total_input_satoshis: 9_000, fee_satoshis: 900, burned_satoshis: 100} =
             Chain.get_transaction!(ctx.burner)

    # Outside the range's completed blocks: untouched.
    assert %{total_output_satoshis: nil, tallies_version: nil} =
             Chain.get_transaction!(ctx.later)

    # No coinbase stored in these fixture blocks, so no reward to check.
    assert %{sats_out: 17_100, fees: 1_900, burned: 100, subsidy: @fifty_btc, fees_verified: nil} =
             Repo.reload!(ctx.b)

    assert Repo.reload!(ctx.b).tallies_version == nil
    assert %{fees: nil, sats_out: 10_000} = Repo.reload!(ctx.a)

    # Script analysis then names the coinbases, and the totals become final.
    Repo.update_all(from(t in Transaction, where: t.txid in ^[ctx.parent, ctx.child]),
      set: [coinbase: true]
    )

    healed = quietly(fn -> Release.backfill_tx_tallies(0, 100, apply: true) end)
    assert %{blocks_below_version: 0, reward_unknown: 0} = healed.details
    assert Repo.reload!(ctx.b).tallies_version == TxPipeline.version(:block_totals)

    output = capture_io(fn -> send(self(), {:report, Release.backfill_tx_tallies(0, 100)}) end)
    assert_received {:report, rerun}

    assert %{rows_examined: 3, rows_changed: 0, rows_below_version: 0, outcome: "ok"} = rerun
    assert %{blocks_changed: 0, blocks_below_version: 0} = rerun.details
    assert output =~ "0 transaction(s) to stamp"
    assert output =~ "0 transaction(s) and 0 block(s) below the version in the range"
    refute output =~ "Run again with apply: true"
  end

  test "picks only rows below the current version", ctx do
    # The child is already at the current version, with values a recompute
    # would replace: the backfill must leave it alone.
    Repo.update_all(from(t in Transaction, where: t.txid == ^ctx.child),
      set: [tallies_version: TxPipeline.version(:tallies), total_output_satoshis: 1]
    )

    # The burner is at an older version: picked.
    Repo.update_all(from(t in Transaction, where: t.txid == ^ctx.burner),
      set: [tallies_version: 0]
    )

    report = quietly(fn -> Release.backfill_tx_tallies(0, 100, apply: true) end)
    assert %{rows_examined: 3, rows_changed: 2, rows_below_version: 0} = report

    assert Chain.get_transaction!(ctx.child).total_output_satoshis == 1
    assert Chain.get_transaction!(ctx.burner).total_output_satoshis == 8_100
    assert Chain.get_transaction!(ctx.parent).total_output_satoshis == 10_000

    # force: true recomputes it anyway.
    quietly(fn -> Release.backfill_tx_tallies(21, 21, apply: true, force: true) end)
    assert Chain.get_transaction!(ctx.child).total_output_satoshis == 9_000
  end

  test "only the height range is scanned", ctx do
    quietly(fn -> Release.backfill_tx_tallies(21, 21, apply: true) end)

    assert Chain.get_transaction!(ctx.parent).total_output_satoshis == nil
    assert Chain.get_transaction!(ctx.child).total_output_satoshis == 9_000
  end

  test "a failing batch records partial with the error and keeps the batches before it", ctx do
    Application.put_env(:bitblocks, :tx_backfill_extra_steps, [RaisesAt21])
    on_exit(fn -> Application.delete_env(:bitblocks, :tx_backfill_extra_steps) end)

    output =
      capture_io(fn ->
        send(self(), {:report, Release.backfill_tx_tallies(0, 100, apply: true, block_batch: 1)})
      end)

    assert_received {:report, report}
    assert %{outcome: "partial", error: "boom at block 21" <> where, rows_changed: 1} = report
    # The recorded error also names where it happened (Derivations.describe/2).
    assert where =~ "RaisesAt21.run_chunk/2"
    assert output =~ "outcome: PARTIAL: boom at block 21"

    # Block 20's batch committed before block 21 failed.
    assert Chain.get_transaction!(ctx.parent).tallies_version == TxPipeline.version(:tallies)
    assert Repo.reload!(ctx.a).subsidy == @fifty_btc
    assert Chain.get_transaction!(ctx.child).tallies_version == nil

    assert %Run{outcome: "partial", error: "boom at block 21" <> _, applied: true} =
             Repo.get!(Run, report.run_id)

    # Fixed, the rerun resumes: only block 21's rows are left.
    Application.delete_env(:bitblocks, :tx_backfill_extra_steps)
    rerun = quietly(fn -> Release.backfill_tx_tallies(0, 100, apply: true) end)
    assert %{outcome: "ok", rows_changed: 2, rows_below_version: 0} = rerun
  end

  test "a failure before any batch finishes records failed" do
    Application.put_env(:bitblocks, :tx_backfill_extra_steps, [RaisesAt21])
    on_exit(fn -> Application.delete_env(:bitblocks, :tx_backfill_extra_steps) end)

    report = quietly(fn -> Release.backfill_tx_tallies(21, 21, apply: true) end)
    assert %{outcome: "failed", rows_changed: 0} = report
    assert %Run{outcome: "failed"} = Repo.get!(Run, report.run_id)
  end

  test "derivation_runs lists the runs, newest first" do
    quietly(fn -> Release.backfill_tx_tallies(0, 100) end)
    quietly(fn -> Release.backfill_tx_tallies(0, 100, apply: true) end)

    output = capture_io(fn -> send(self(), {:runs, Release.derivation_runs(limit: 2)}) end)
    assert_received {:runs, [newest, older]}

    assert newest.applied and not older.applied
    assert output =~ "tallies v#{TxPipeline.version(:tallies)} 0..100 applied ok"
    assert output =~ "dry run ok"
  end
end
