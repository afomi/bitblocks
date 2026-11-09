defmodule Bitblocks.Reorgs.ReconcileTest do
  # #34: after a reorg, transaction rows still point at the orphaned block's
  # hash. Reconcile moves each one to the block that now holds it, and removes
  # the ones no block holds, with their spend edges.
  use Bitblocks.DataCase

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{Spend, Transaction}
  alias Bitblocks.Reorgs
  alias Bitblocks.Reorgs.Reconcile
  alias BitblocksWeb.RpcStub

  @orphan "orphan_900101"
  @replacement "replacement_900101"
  @later "canon_900102"

  setup do
    # No node stubs: every node lookup fails, so answers come from WoC.
    RpcStub.setup()
    RpcStub.clear()

    block_fixture(%{height: 900_100, hash: "ancestor_900100", merkleroot: nil, num_tx: 1})

    block_fixture(%{
      height: 900_101,
      hash: @replacement,
      merkleroot: nil,
      num_tx: 2,
      tx: ["tx_shared", "tx_new_only"],
      sync_state: "completed"
    })

    block_fixture(%{height: 900_102, hash: @later, merkleroot: nil, num_tx: 1})

    for txid <- ~w(tx_shared tx_later tx_orphan_only tx_mempool tx_pending) do
      transaction_fixture(%{txid: txid, block_hash: @orphan, block_height: 900_101})
    end

    transaction_fixture(%{txid: "tx_elsewhere", block_hash: @later, block_height: 900_102})

    spend("prev_a", 0, "tx_orphan_only")
    spend("prev_b", 0, "tx_shared")
    spend("prev_c", 1, "tx_mempool")

    Process.put(:woc_txs, %{
      "tx_later" => %{"txid" => "tx_later", "blockhash" => @later, "blockheight" => 900_102},
      "tx_mempool" => %{"txid" => "tx_mempool", "confirmations" => 0},
      "tx_pending" => %{
        "txid" => "tx_pending",
        "blockhash" => "not_stored_yet",
        "blockheight" => 900_150
      }
    })

    :ok
  end

  defp spend(txid, vout, spending_txid) do
    Repo.insert!(%Spend{txid: txid, vout: vout, spending_txid: spending_txid, spending_vin: 0})
  end

  defp tx(txid), do: Repo.get_by(Transaction, txid: txid)

  defp spenders,
    do:
      Repo.all(
        from(s in Spend, where: s.txid in ["prev_a", "prev_b", "prev_c"], select: s.spending_txid)
      )
      |> Enum.sort()

  test "the plan sorts every row by where its transaction is now, and changes nothing" do
    assert {:ok, plan} = Reconcile.plan(@orphan)

    assert plan.height == 900_101
    assert plan.rows == 5

    assert plan.repoint == [
             {@replacement, 900_101, ["tx_shared"]},
             {@later, 900_102, ["tx_later"]}
           ]

    assert Enum.sort(plan.remove) == ["tx_mempool", "tx_orphan_only"]
    assert plan.pending == ["tx_pending"]
    assert plan.unknown == []
    assert plan.spends_to_remove == 2

    assert tx("tx_shared").block_hash == @orphan
    assert tx("tx_orphan_only")
    assert spenders() == ~w(tx_mempool tx_orphan_only tx_shared)
  end

  test "applying moves re-mined transactions and removes orphan-only ones" do
    {:ok, plan} = Reconcile.plan(@orphan)
    assert {:ok, result} = Reconcile.apply_plan(plan)

    assert %{repointed: 2, removed: 2, spends_removed: 2, remaining: 1} = result

    # The tx mined in both blocks now reports the new block hash and height.
    assert %{block_hash: @replacement, block_height: 900_101} = tx("tx_shared")
    assert %{block_hash: @later, block_height: 900_102} = tx("tx_later")
    refute tx("tx_orphan_only")
    refute tx("tx_mempool")
    # Its block isn't stored yet: the fetch for that block moves it.
    assert tx("tx_pending").block_hash == @orphan
    assert tx("tx_elsewhere").block_hash == @later

    assert spenders() == ["tx_shared"]
  end

  test "a failed lookup leaves the row where it is" do
    Process.put(:woc_txs_error, {:http_status, 500, "down"})

    {:ok, plan} = Reconcile.plan(@orphan)

    # Only the replacement block's verified txid list answers.
    assert plan.repoint == [{@replacement, 900_101, ["tx_shared"]}]
    assert plan.remove == []

    assert Enum.sort(plan.unknown) ==
             ~w(tx_later tx_mempool tx_orphan_only tx_pending)

    {:ok, result} = Reconcile.apply_plan(plan)
    assert result.removed == 0
    assert result.remaining == 4
    assert tx("tx_orphan_only").block_hash == @orphan
  end

  # 2026-11-04, the 957,301 orphan: the node and WhatsOnChain both still name
  # the orphaned block, with 0 / null confirmations. That block is off the
  # chain, and the tx isn't in the replacement's verified list, so no block
  # on the chain holds it.
  test "a source naming the orphan with no confirmations means no block holds it" do
    Process.put(:woc_txs, %{
      "tx_orphan_only" => %{
        "txid" => "tx_orphan_only",
        "blockhash" => @orphan,
        "confirmations" => 0
      },
      "tx_mempool" => %{"txid" => "tx_mempool", "blockhash" => @orphan, "confirmations" => nil}
    })

    {:ok, plan} = Reconcile.plan(@orphan)

    assert "tx_orphan_only" in plan.remove
    assert "tx_mempool" in plan.remove
    refute "tx_orphan_only" in plan.unknown
  end

  test "a source still confirming the orphan is a contradiction to ask about later" do
    Process.put(:woc_txs, %{
      "tx_orphan_only" => %{
        "txid" => "tx_orphan_only",
        "blockhash" => @orphan,
        "confirmations" => 3
      }
    })

    {:ok, plan} = Reconcile.plan(@orphan)
    assert "tx_orphan_only" in plan.unknown
  end

  test "refuses a hash that is still a stored block" do
    assert {:error, :block_still_stored} = Reconcile.plan(@replacement)
  end

  test "an orphan with no rows has nothing to do" do
    assert {:ok, plan} = Reconcile.plan("orphan_with_no_rows")
    assert plan.rows == 0
    assert {:ok, %{remaining: 0}} = Reconcile.apply_plan(plan)
  end

  test "an orphan with no rows takes its height from the node, so its reorg row is found" do
    {:ok, reorg} =
      Reorgs.record_observed(
        %{fork_height: 900_102, fork_point: 900_100, orphan_count: 1, outcome: "resolved"},
        ~U[2026-11-04 00:56:00Z]
      )

    RpcStub.stub_getblockheader("orphan_gone", %{"hash" => "orphan_gone", "height" => 900_101})

    assert {:ok, report} = Reconcile.run("orphan_gone", apply: true)
    assert report.plan.height == 900_101
    assert report.reorg.id == reorg.id
    assert Repo.get!(Bitblocks.Reorgs.Reorg, reorg.id).txs_reconciled_at

    # A block the node doesn't know either has no height, and no reorg row to mark.
    assert {:ok, %{plan: %{height: nil}, reorg: nil}} = Reconcile.run("orphan_unknown")
  end

  describe "run/2 and the reorg row" do
    setup do
      {:ok, reorg} =
        Reorgs.record_observed(
          %{fork_height: 900_102, fork_point: 900_100, orphan_count: 2, outcome: "resolved"},
          ~U[2026-11-04 00:56:00Z]
        )

      %{reorg: reorg}
    end

    test "a dry run reports the reorg row it would correct and writes nothing", %{reorg: reorg} do
      assert {:ok, report} = Reconcile.run(@orphan, orphan_count: 1)

      refute report.applied
      assert report.reorg.id == reorg.id
      assert report.reorg_changes.orphan_count == {2, 1}
      assert tx("tx_orphan_only")
      assert Repo.get!(Bitblocks.Reorgs.Reorg, reorg.id).orphan_count == 2
    end

    test "rows left pending keep the sentence saying transaction rows remain", %{reorg: reorg} do
      assert {:ok, report} = Reconcile.run(@orphan, apply: true, orphan_count: 1)

      assert report.applied
      assert report.result.remaining == 1
      updated = Repo.get!(Bitblocks.Reorgs.Reorg, reorg.id)
      assert updated.orphan_count == 1
      assert is_nil(updated.txs_reconciled_at)
      assert updated.summary =~ "still in this index"
      assert updated.summary =~ "1 block above that height"
    end

    test "with every row settled, the reorg is marked reconciled", %{reorg: reorg} do
      Process.put(
        :woc_txs,
        Map.put(Process.get(:woc_txs), "tx_pending", %{
          "txid" => "tx_pending",
          "blockhash" => @later,
          "blockheight" => 900_102
        })
      )

      assert {:ok, report} = Reconcile.run(@orphan, apply: true)

      assert report.result.remaining == 0
      updated = Repo.get!(Bitblocks.Reorgs.Reorg, reorg.id)
      assert updated.txs_reconciled_at
      refute updated.summary =~ "still in this index"
      # Without an orphan_count option, the count is left as recorded.
      assert updated.orphan_count == 2
    end
  end
end
