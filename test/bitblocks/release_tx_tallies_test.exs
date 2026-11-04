defmodule Bitblocks.ReleaseTxTalliesTest do
  # The tallies backfill for blocks completed before the tally steps: dry run
  # by default, apply: true writes, and a second run finds nothing to do.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, RawBlock, Transaction, TxIngest}
  alias Bitblocks.Release

  @fifty_btc 5_000_000_000

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  # Two completed blocks stored as the ingest did before the tally steps:
  # the tally columns and block totals empty.
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
        burned_satoshis: nil
      ]
    )

    Repo.update_all(Block,
      set: [
        sats_out: nil,
        fees: nil,
        miner_reward: nil,
        subsidy: nil,
        burned: nil,
        fees_verified: nil
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

  test "a dry run counts what would change and writes nothing", ctx do
    output = capture_io(fn -> send(self(), {:report, Release.backfill_tx_tallies(0, 100)}) end)
    assert_received {:report, report}

    assert %{
             applied: false,
             blocks: 2,
             txs: 3,
             txs_changed: 3,
             sats_in_unknown: 1,
             blocks_changed: 2,
             unverified: []
           } = report

    assert output =~ "DRY RUN (nothing written)"
    assert output =~ "3 transaction(s) to update"
    assert output =~ "Run again with apply: true"

    assert Chain.get_transaction!(ctx.child).total_input_satoshis == nil
    assert Repo.reload!(ctx.b).sats_out == nil
  end

  test "apply: true writes the tallies and block totals; a rerun finds nothing", ctx do
    capture_io(fn -> Release.backfill_tx_tallies(0, 100, apply: true, tx_batch: 1) end)

    assert %{total_input_satoshis: nil, total_output_satoshis: 10_000, fee_satoshis: nil} =
             Chain.get_transaction!(ctx.parent)

    assert %{total_input_satoshis: 10_000, total_output_satoshis: 9_000, fee_satoshis: 1_000} =
             Chain.get_transaction!(ctx.child)

    assert %{total_input_satoshis: 9_000, fee_satoshis: 900, burned_satoshis: 100} =
             Chain.get_transaction!(ctx.burner)

    # Outside the range's completed blocks: untouched.
    assert Chain.get_transaction!(ctx.later).total_output_satoshis == nil

    # No coinbase stored in these fixture blocks, so no reward to check.
    assert %{sats_out: 17_100, fees: 1_900, burned: 100, subsidy: @fifty_btc, fees_verified: nil} =
             Repo.reload!(ctx.b)

    assert %{fees: nil, sats_out: 10_000} = Repo.reload!(ctx.a)

    rerun = capture_io(fn -> send(self(), {:report, Release.backfill_tx_tallies(0, 100)}) end)
    assert_received {:report, %{txs_changed: 0, blocks_changed: 0}}
    assert rerun =~ "0 transaction(s) to update"
  end

  test "only the height range is scanned", ctx do
    capture_io(fn -> Release.backfill_tx_tallies(21, 21, apply: true) end)

    assert Chain.get_transaction!(ctx.parent).total_output_satoshis == nil
    assert Chain.get_transaction!(ctx.child).total_output_satoshis == 9_000
  end
end
