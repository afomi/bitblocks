defmodule Bitblocks.ReleaseTxTypesTest do
  # The tx types backfill (docs/DERIVED_DATA.md, #49): picks rows below the
  # current tx_types_version and stamps them, rewrites the block's
  # type_counts, a rerun finds nothing, and a dry run writes only its run
  # record.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, RawBlock, Transaction, TxIngest, TxPipeline}
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Release

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  defp quietly(fun) do
    capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  # Two completed blocks and one still syncing, stored as the ingest did
  # before the classify_outputs step: no types and no stamps.
  setup do
    a = block_fixture(%{height: 40, sync_state: "completed"})
    b = block_fixture(%{height: 41, sync_state: "completed"})
    pending = block_fixture(%{height: 42, sync_state: "header_only"})

    {pay_txid, _} = pay = tx([funding_outpoint()], [p2pkh(address(), 10_000)])

    memo = %BSV.TxOut{satoshis: 0, script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "hi"]}}
    {memo_txid, _} = memo_tx = tx(["#{pay_txid}_0"], [p2pkh(address(), 9_000), memo])

    p2pk = %BSV.TxOut{
      satoshis: 500,
      script: %BSV.Script{chunks: [:binary.copy(<<2>>, 33), :OP_CHECKSIG]}
    }

    {odd_txid, _} = odd = tx(["#{memo_txid}_0"], [p2pk])
    {later_txid, _} = later = tx([funding_outpoint()], [p2pkh(address(), 1)])

    :ok = TxIngest.store(tx_json(pay), a)
    [_, _] = TxIngest.store_chunk([tx_json(memo_tx), tx_json(odd)], b)
    :ok = TxIngest.store(tx_json(later), pending)

    Repo.update_all(Transaction, set: [tx_types: nil, tx_types_version: nil])
    Repo.update_all(Block, set: [type_counts: nil, type_counts_version: nil])

    %{a: a, b: b, pay: pay_txid, memo: memo_txid, odd: odd_txid, later: later_txid}
  end

  test "a dry run counts what it would stamp, writes nothing, and records a run", ctx do
    output = capture_io(fn -> send(self(), {:report, Release.backfill_tx_types(0, 100)}) end)
    assert_received {:report, report}

    assert %{
             applied: false,
             outcome: "ok",
             blocks_examined: 2,
             rows_examined: 3,
             rows_changed: 3,
             rows_below_version: 3,
             details: %{
               types_changed: 3,
               undecodable: 0,
               blocks_changed: 2,
               blocks_below_version: 2
             }
           } = report

    assert output =~ "DRY RUN (nothing written)"
    assert output =~ "3 transaction(s) to stamp v#{TxPipeline.version(:tx_types)}"
    assert output =~ "3 transaction(s) and 2 block(s) below the version in the range"
    assert output =~ "Run again with apply: true"

    assert Chain.get_transaction!(ctx.memo).tx_types == nil
    assert Repo.reload!(ctx.b).type_counts == nil

    assert %Run{derivation: "tx_types", applied: false, outcome: "ok", rows_changed: 3} =
             Repo.get!(Run, report.run_id)
  end

  test "apply types every tx of completed blocks, tallies the blocks, and a rerun finds nothing",
       ctx do
    report = quietly(fn -> Release.backfill_tx_types(0, 100, apply: true) end)

    assert %{applied: true, outcome: "ok", rows_changed: 3, rows_below_version: 0} = report
    assert report.details.blocks_below_version == 0

    assert Chain.get_transaction!(ctx.pay).tx_types == ["p2pkh"]
    assert Chain.get_transaction!(ctx.memo).tx_types == ["p2pkh", "op-return"]
    assert Chain.get_transaction!(ctx.odd).tx_types == ["p2pk"]

    for txid <- [ctx.pay, ctx.memo, ctx.odd] do
      assert Chain.get_transaction!(txid).tx_types_version == TxPipeline.version(:tx_types)
    end

    # The block that is still syncing is left to the ingest.
    assert Chain.get_transaction!(ctx.later).tx_types_version == nil

    assert %{type_counts: %{"p2pkh" => 1}} = Repo.reload!(ctx.a)

    b = Repo.reload!(ctx.b)
    assert b.type_counts == %{"p2pkh" => 1, "op-return" => 1, "p2pk" => 1}
    assert b.type_counts_version == TxPipeline.version(:type_counts)

    rerun = quietly(fn -> Release.backfill_tx_types(0, 100) end)
    assert %{rows_changed: 0, rows_below_version: 0, outcome: "ok"} = rerun
    assert rerun.details.blocks_changed == 0
  end

  test "a range only touches its own blocks", ctx do
    quietly(fn -> Release.backfill_tx_types(41, 41, apply: true) end)

    assert Chain.get_transaction!(ctx.pay).tx_types_version == nil
    assert Chain.get_transaction!(ctx.memo).tx_types_version == TxPipeline.version(:tx_types)
    assert Repo.reload!(ctx.a).type_counts_version == nil
  end
end
