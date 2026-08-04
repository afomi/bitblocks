defmodule Bitblocks.Workers.BackfillTransactionsWorkerTest do
  use Bitblocks.DataCase

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain
  alias Bitblocks.Workers.BackfillTransactionsWorker
  alias BitblocksWeb.RpcStub

  # Real genesis block: single tx whose id equals the merkleroot, with the raw
  # body that actually hashes to it — passes both the merkleroot gate and the
  # per-body txid check.
  @genesis_txid "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
  @genesis_raw "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

  setup do
    RpcStub.setup()
    RpcStub.clear()
    :ok
  end

  defp genesis_tx_json(block) do
    %{
      "txid" => @genesis_txid,
      "hex" => @genesis_raw,
      "blockhash" => block.hash,
      "height" => block.height,
      "version" => 1,
      "vin" => [%{"coinbase" => "04ffff001d0104", "sequence" => 4_294_967_295}],
      "vout" => []
    }
  end

  describe "self-healing: txs_syncing blocks are not stranded" do
    test "a txs_syncing block whose txs are all stored is picked up and completed" do
      # Reproduces the prod orphan: a worker died mid-fetch leaving the block in
      # txs_syncing. Previously next_incomplete_block excluded that state, so the
      # block was stranded forever. Now it's eligible, and since all its txs are
      # already stored, the run completes it without a node.
      # (merkleroot: nil — fixture txids aren't real hashes, so the merkle gate
      # is skipped; TxidSource logs the skip.)
      tx = transaction_fixture(%{})

      block =
        block_fixture(%{
          height: 152_758,
          hash: "stranded_block",
          num_tx: 1,
          tx: [tx.txid],
          merkleroot: nil,
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
          merkleroot: nil,
          sync_state: "header_synced"
        })

      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      assert Chain.get_block!(block.height).sync_state == "completed"
    end

    test "an orphaned txs_queued block (no live Oban job) is picked up" do
      tx = transaction_fixture(%{})

      block =
        block_fixture(%{
          height: 152_761,
          hash: "orphaned_queued_block",
          num_tx: 1,
          tx: [tx.txid],
          merkleroot: nil,
          sync_state: "txs_queued"
        })

      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      assert Chain.get_block!(block.height).sync_state == "completed"
    end

    test "a txs_queued block with an active fetch job is left alone" do
      tx = transaction_fixture(%{})

      block =
        block_fixture(%{
          height: 152_762,
          hash: "actively_queued_block",
          num_tx: 1,
          tx: [tx.txid],
          merkleroot: nil,
          sync_state: "txs_queued"
        })

      Repo.insert!(%Oban.Job{
        worker: "Bitblocks.Workers.FetchTransactionsWorker",
        queue: "transactions_backfill",
        state: "available",
        args: %{"block_hash" => block.hash}
      })

      # Nothing else is incomplete, so the run is a no-op :ok and the block
      # stays queued for its live job.
      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      assert Chain.get_block!(block.height).sync_state == "txs_queued"
    end
  end

  describe "retry budget (the spin-loop brake)" do
    test "a permanently-failing block stops being re-selected once it exhausts its attempts" do
      # THE REGRESSION TEST. Before the fix, a block that could not complete was
      # marked "failed", then immediately re-selected as the lowest incomplete
      # block on the very next pass — forever. With the worker rescheduling
      # itself every 1s across 2 instances, that was the hot loop responsible
      # for ~131M index scans against a 1,548-row `blocks` table.
      #
      # The node stub has no response for this txid, so every pass fails.
      # Attempts must accumulate and selection must stop at @max_attempts (3).
      block =
        block_fixture(%{
          height: 152_770,
          hash: "permanently_failing_block",
          num_tx: 1,
          tx: [String.duplicate("ab", 32)],
          merkleroot: nil,
          sync_state: "header_synced"
        })

      for expected <- 1..3 do
        assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})
        assert Chain.get_block!(block.height).tx_sync_attempts == expected
      end

      # Budget spent. The block is no longer eligible, so this pass finds
      # nothing and the loop goes idle rather than picking the same block again.
      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})
      assert Chain.get_block!(block.height).tx_sync_attempts == 3
    end

    test "retry_failed_blocks clears the counter so a transient failure can resume" do
      # The budget must not permanently strand blocks that failed because the
      # node was down. Resetting attempts makes them eligible again.
      block =
        block_fixture(%{
          height: 152_771,
          hash: "transiently_failed_block",
          num_tx: 1,
          tx: [String.duplicate("ab", 32)],
          merkleroot: nil,
          sync_state: "failed",
          tx_sync_attempts: 3
        })

      # Exhausted — not selected.
      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})
      assert Chain.get_block!(block.height).tx_sync_attempts == 3

      Bitblocks.Repo.update_all(
        Ecto.Query.from(b in Chain.Block, where: b.hash == ^block.hash),
        set: [tx_sync_attempts: 0]
      )

      # Eligible again: it gets picked up and re-attempted.
      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})
      assert Chain.get_block!(block.height).tx_sync_attempts == 1
    end
  end

  describe "completeness gate (no silent incompleteness)" do
    test "a block whose txs can't be fetched is marked failed, not completed" do
      # The single txid is not stored and the node stub has no response for it,
      # so the batch reports unfetched and the completeness gate refuses to
      # complete. The block must end `failed` (and Oban retries), never
      # `completed` with a hole. Reliability/completeness over throughput.
      block =
        block_fixture(%{
          height: 152_760,
          hash: "unfetchable_block",
          num_tx: 1,
          tx: [String.duplicate("ab", 32)],
          merkleroot: nil,
          sync_state: "header_synced"
        })

      # perform/1 returns :ok — the FAILURE IS RECORDED ON THE BLOCK, not
      # signalled to Oban. Returning {:error, _} would make Oban retry the job
      # on top of the block's own tx_sync_attempts budget: two stacked retry
      # mechanisms, which is what produced the 1s spin loop against `blocks`.
      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      reloaded = Chain.get_block!(block.height)
      assert reloaded.sync_state == "failed"
      assert reloaded.tx_sync_attempts == 1
    end

    test "a tx whose body doesn't hash to its txid is rejected and the block fails" do
      fake_txid = String.duplicate("cd", 32)

      block =
        block_fixture(%{
          height: 152_763,
          hash: "poisoned_body_block",
          num_tx: 1,
          tx: [fake_txid],
          merkleroot: nil,
          sync_state: "header_synced"
        })

      # The node returns the genesis body under a different txid — the T4
      # body-hash check must reject it.
      RpcStub.stub_getrawtransaction(fake_txid, 1, %{
        "txid" => fake_txid,
        "hex" => @genesis_raw,
        "version" => 1,
        "vin" => [],
        "vout" => []
      })

      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      assert Chain.get_block!(block.height).sync_state == "failed"
      assert Repo.get_by(Chain.Transaction, txid: fake_txid) == nil
    end
  end

  describe "empty stored tx array (the >10k truncation / missing-array hole)" do
    test "a block with tx: [] and num_tx > 0 re-fetches its txid list and completes with rows" do
      # Previously: total = length(block.tx) = 0, the gate passed trivially, and
      # the block was marked completed with ZERO transactions stored. Now the
      # txid list is re-fetched from the node and verified, and the block only
      # completes once the transaction is actually stored.
      block =
        block_fixture(%{
          height: 0,
          hash: "genesis_empty_array",
          num_tx: 1,
          tx: [],
          merkleroot: @genesis_txid,
          sync_state: "header_synced"
        })

      RpcStub.stub_getblock(block.hash, 1, %{"hash" => block.hash, "tx" => [@genesis_txid]})
      RpcStub.stub_getrawtransaction(@genesis_txid, 1, genesis_tx_json(block))

      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      assert Chain.get_block!(block.height).sync_state == "completed"
      assert %Chain.Transaction{} = Repo.get_by(Chain.Transaction, txid: @genesis_txid)
    end

    test "a block whose re-fetched list can't be verified fails closed" do
      block =
        block_fixture(%{
          height: 170,
          hash: "poisoned_list_block",
          num_tx: 1,
          tx: [],
          merkleroot: @genesis_txid,
          sync_state: "header_synced"
        })

      # Node returns a txid list that doesn't rebuild the header merkleroot.
      RpcStub.stub_getblock(block.hash, 1, %{
        "hash" => block.hash,
        "tx" => [String.duplicate("ef", 32)]
      })

      # Fails closed: the block is never completed, and the failure is now
      # recorded against tx_sync_attempts so an unverifiable block eventually
      # stops being re-selected instead of spinning forever.
      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})

      reloaded = Chain.get_block!(block.height)
      refute reloaded.sync_state == "completed"
      assert reloaded.tx_sync_attempts == 1
    end
  end

  describe "idempotency (diff-and-fill)" do
    test "only missing txids are fetched; a second pass makes no tx fetches" do
      stored = transaction_fixture(%{})
      missing_txid = @genesis_txid

      block =
        block_fixture(%{
          height: 152_764,
          hash: "diff_fill_block",
          num_tx: 2,
          tx: [stored.txid, missing_txid],
          merkleroot: nil,
          sync_state: "header_synced"
        })

      RpcStub.stub_getrawtransaction(missing_txid, 1, genesis_tx_json(block))

      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})
      assert Chain.get_block!(block.height).sync_state == "completed"

      # The already-stored txid was never requested — only the gap was fetched.
      assert [[[^missing_txid], 1]] = RpcStub.calls(:batch_getrawtransaction)

      # Second pass over the same block: everything is stored, zero fetches.
      Chain.get_block!(block.height)
      |> Ecto.Changeset.change(%{sync_state: "header_synced"})
      |> Repo.update!()

      RpcStub.clear()
      assert :ok = BackfillTransactionsWorker.perform(%Oban.Job{args: %{}})
      assert Chain.get_block!(block.height).sync_state == "completed"
      assert RpcStub.calls(:batch_getrawtransaction) == []
    end
  end
end
