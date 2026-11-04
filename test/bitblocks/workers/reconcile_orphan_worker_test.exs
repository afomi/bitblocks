defmodule Bitblocks.Workers.ReconcileOrphanWorkerTest do
  use Bitblocks.DataCase

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.Transaction
  alias Bitblocks.Reorgs
  alias Bitblocks.Workers.ReconcileOrphanWorker
  alias BitblocksWeb.RpcStub

  setup do
    RpcStub.setup()
    RpcStub.clear()

    block_fixture(%{
      height: 900_301,
      hash: "replacement_900301",
      merkleroot: nil,
      num_tx: 1,
      tx: ["tx_both"]
    })

    transaction_fixture(%{txid: "tx_both", block_hash: "orphan_900301", block_height: 900_301})
    transaction_fixture(%{txid: "tx_gone", block_hash: "orphan_900301", block_height: 900_301})

    {:ok, reorg} =
      Reorgs.record_observed(
        %{fork_height: 900_301, fork_point: 900_300, orphan_count: 1, outcome: "resolved"},
        ~U[2026-11-04 00:56:00Z]
      )

    %{reorg: reorg}
  end

  test "reconciles the orphan's rows and marks the reorg reconciled", %{reorg: reorg} do
    assert :ok =
             ReconcileOrphanWorker.perform(%Oban.Job{args: %{"orphan_hash" => "orphan_900301"}})

    assert Repo.get_by(Transaction, txid: "tx_both").block_hash == "replacement_900301"
    refute Repo.get_by(Transaction, txid: "tx_gone")
    assert Repo.get!(Reorgs.Reorg, reorg.id).txs_reconciled_at
  end

  test "rows it couldn't place are an error, so Oban tries again later" do
    Process.put(:woc_txs_error, {:http_status, 500, "down"})

    assert {:error, {:unreconciled, 1}} =
             ReconcileOrphanWorker.perform(%Oban.Job{args: %{"orphan_hash" => "orphan_900301"}})

    assert Repo.get_by(Transaction, txid: "tx_gone")
  end
end
