defmodule Bitblocks.Workers.BackfillTransactionsWorkerTest do
  use Bitblocks.DataCase

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain
  alias Bitblocks.Workers.BackfillTransactionsWorker

  describe "self-healing: txs_syncing blocks are not stranded" do
    test "a txs_syncing block whose txs are all stored is picked up and completed" do
      # Reproduces the prod orphan: a worker died mid-fetch leaving the block in
      # txs_syncing. Previously next_incomplete_block excluded that state, so the
      # block was stranded forever. Now it's eligible, and since all its txs are
      # already stored, the run completes it without a node.
      tx = transaction_fixture(%{})

      block =
        block_fixture(%{
          height: 152_758,
          hash: "stranded_block",
          num_tx: 1,
          tx: [tx.txid],
          sync_state: "txs_syncing"
        })

      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      assert Chain.get_block!(block.height).sync_state == "completed"
    end

    test "completeness counts the block's txids regardless of which block_hash they were stored under" do
      # tx stored under a DIFFERENT block_hash (reorg / dup). A block_hash-scoped
      # existing-check would never see it, recompute the same missing set, and
      # loop forever. Intersecting by txid lets the block complete.
      tx = transaction_fixture(%{block_hash: "some_other_block"})

      block =
        block_fixture(%{
          height: 152_759,
          hash: "intersection_block",
          num_tx: 1,
          tx: [tx.txid],
          sync_state: "header_synced"
        })

      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      assert Chain.get_block!(block.height).sync_state == "completed"
    end
  end

  describe "completeness gate (no silent incompleteness)" do
    test "a block whose txs can't be fetched is marked failed, not completed" do
      # The single txid is not stored and there is no node to fetch it, so the
      # batch reports unfetched and the completeness gate refuses to complete.
      # The block must end `failed` (and Oban retries), never `completed` with a
      # hole. Reliability/completeness over throughput.
      block =
        block_fixture(%{
          height: 152_760,
          hash: "unfetchable_block",
          num_tx: 1,
          tx: [String.duplicate("ab", 32)],
          sync_state: "header_synced"
        })

      assert {:error, _} = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      assert Chain.get_block!(block.height).sync_state == "failed"
    end
  end
end
