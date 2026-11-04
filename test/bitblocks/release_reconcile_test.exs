defmodule Bitblocks.ReleaseReconcileTest do
  # The prod repair for the 957,301 reorg (#34): dry run by default.
  use Bitblocks.DataCase

  import Bitblocks.ChainFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.Chain.{Spend, Transaction}
  alias Bitblocks.Release
  alias Bitblocks.Reorgs
  alias BitblocksWeb.RpcStub

  @orphan "orphan_957301_test"

  setup do
    RpcStub.setup()
    RpcStub.clear()

    block_fixture(%{
      height: 957_301,
      hash: "real_957301_test",
      merkleroot: nil,
      num_tx: 1,
      tx: ["tx_both"]
    })

    transaction_fixture(%{txid: "tx_both", block_hash: @orphan, block_height: 957_301})
    transaction_fixture(%{txid: "tx_gone", block_hash: @orphan, block_height: 957_301})
    Repo.insert!(%Spend{txid: "prev", vout: 0, spending_txid: "tx_gone", spending_vin: 0})

    {:ok, reorg} =
      Reorgs.record_observed(
        %{fork_height: 957_302, fork_point: 957_300, orphan_count: 2, outcome: "resolved"},
        ~U[2026-11-04 00:56:00Z]
      )

    %{reorg: reorg}
  end

  test "a dry run prints what would change and changes nothing", %{reorg: reorg} do
    {result, io} =
      with_io(fn -> Release.reconcile_orphaned_block(@orphan, orphan_count: 1) end)

    assert {:ok, %{applied: false}} = result
    assert io =~ "DRY RUN"
    assert io =~ "2 transaction row(s)"
    assert io =~ "move 1 to real_957301_test (height 957301)"
    assert io =~ "remove 1 (no block holds them)"
    assert io =~ "remove 1 spend edge(s)"
    assert io =~ "orphan_count 2 -> 1"
    assert io =~ "apply: true"

    assert Repo.get_by(Transaction, txid: "tx_both").block_hash == @orphan
    assert Repo.get_by(Transaction, txid: "tx_gone")
    assert Repo.get_by(Spend, txid: "prev", vout: 0)
    assert Repo.get!(Reorgs.Reorg, reorg.id).orphan_count == 2
  end

  test "apply: true reconciles the rows and corrects the reorg row", %{reorg: reorg} do
    {result, io} =
      with_io(fn ->
        Release.reconcile_orphaned_block(@orphan, apply: true, orphan_count: 1)
      end)

    assert {:ok, %{applied: true}} = result
    assert io =~ "APPLIED"
    assert io =~ "0 row(s) still point at the orphan"

    assert Repo.get_by(Transaction, txid: "tx_both").block_hash == "real_957301_test"
    refute Repo.get_by(Transaction, txid: "tx_gone")
    refute Repo.get_by(Spend, txid: "prev", vout: 0)

    updated = Repo.get!(Reorgs.Reorg, reorg.id)
    assert updated.orphan_count == 1
    assert updated.txs_reconciled_at
    assert updated.summary =~ "1 block between those heights was set aside."
    refute updated.summary =~ "still in this index"
  end

  test "a hash that is still a stored block is refused" do
    {result, io} = with_io(fn -> Release.reconcile_orphaned_block("real_957301_test") end)

    assert {:error, :block_still_stored} = result
    assert io =~ "still a stored block"
  end

  test "with_running_repo runs in place when the app is up (rpc)" do
    assert Bitblocks.Release.with_running_repo(fn -> :ran end) == :ran
  end
end
