defmodule Bitblocks.Workers.SyncHeadersWorkerTest do
  use Bitblocks.DataCase

  alias Bitblocks.Chain
  alias Bitblocks.Chain.Block
  alias Bitblocks.Workers.SyncHeadersWorker

  import Bitblocks.ChainFixtures

  describe "range mode — gap detection" do
    test "missing_block_ranges finds gaps in block coverage" do
      # Create blocks 0, 1, 2, 5, 6 — gaps at 3..4
      for h <- [0, 1, 2, 5, 6] do
        block_fixture(%{height: h, hash: "hash_#{h}"})
      end

      gaps = Chain.missing_block_ranges(0, 6)
      assert gaps == [{3, 4}]
    end

    test "no gaps returns empty list" do
      for h <- 0..3 do
        block_fixture(%{height: h, hash: "hash_#{h}"})
      end

      gaps = Chain.missing_block_ranges(0, 3)
      assert gaps == []
    end
  end

  describe "range mode — idempotent inserts" do
    test "inserting a block that already exists is a no-op" do
      existing = block_fixture(%{height: 100, hash: "existing_hash"})

      # Simulate what the worker does: insert with on_conflict: :nothing
      duplicate = %Block{
        hash: "existing_hash",
        height: 100,
        num_tx: 0,
        time: 42,
        bits: "bits",
        chainwork: "",
        difficulty: "1",
        mediantime: 42,
        merkleroot: "mr",
        prevblockhash: "",
        nextblockhash: "",
        nonce: 0,
        version: 1,
        tx: [],
        sync_state: "header_only"
      }

      result = Repo.insert(Ecto.Changeset.change(duplicate, %{}), on_conflict: :nothing)

      # on_conflict: :nothing returns {:ok, %{id: nil}} for conflicts
      assert {:ok, %{id: nil}} = result

      # Original block untouched
      assert Chain.get_block!(100).id == existing.id
    end
  end

  describe "job enqueueing" do
    test "range job can be created with valid args" do
      changeset =
        SyncHeadersWorker.new(%{"mode" => "range", "from" => 0, "to" => 100})

      assert changeset.valid?
      assert changeset.changes.args == %{"mode" => "range", "from" => 0, "to" => 100}
      assert changeset.changes.queue == "blocks"
    end

    test "tip job can be created" do
      changeset = SyncHeadersWorker.new(%{"mode" => "tip"})

      assert changeset.valid?
      assert changeset.changes.args == %{"mode" => "tip"}
    end

    test "tip job with schedule_in sets scheduled_at" do
      changeset = SyncHeadersWorker.new(%{"mode" => "tip"}, schedule_in: 30)

      assert changeset.valid?
      assert changeset.changes.scheduled_at
    end
  end

  describe "prevhash continuity (threat T4)" do
    test "accepts a header that chains onto the predecessor we hold" do
      predecessor = %Block{hash: "prev_block_hash_abc"}
      header = %{"previousblockhash" => "prev_block_hash_abc"}

      assert :ok = SyncHeadersWorker.continuity(predecessor, header)
    end

    test "rejects a header whose previousblockhash doesn't match the predecessor (off-chain)" do
      predecessor = %Block{hash: "the_real_prev_hash"}
      header = %{"previousblockhash" => "some_other_fork_hash"}

      assert {:error, :prevhash_mismatch} = SyncHeadersWorker.continuity(predecessor, header)
    end

    test "allows insertion when the predecessor isn't present yet (out-of-order gap fill)" do
      header = %{"previousblockhash" => "anything"}
      assert :ok = SyncHeadersWorker.continuity(nil, header)
    end

    # Real-world regression: block 953597 was false-rejected despite chaining
    # cleanly onto 953596 (verified against WhatsOnChain + node operator).
    # Guards against case/whitespace normalization regressions.
    test "accepts real block 953597 chaining onto stored 953596" do
      predecessor = %Block{hash: "0000000000000000158116981dd2a2b78eb0388662cbf30b856cf7188e76b7f2"}
      header = %{"previousblockhash" => "0000000000000000158116981dd2a2b78eb0388662cbf30b856cf7188e76b7f2"}
      assert :ok = SyncHeadersWorker.continuity(predecessor, header)
    end

    test "accepts when stored hash is uppercase and node returns lowercase" do
      predecessor = %Block{hash: "0000000000000000158116981DD2A2B78EB0388662CBF30B856CF7188E76B7F2"}
      header = %{"previousblockhash" => "0000000000000000158116981dd2a2b78eb0388662cbf30b856cf7188e76b7f2"}
      assert :ok = SyncHeadersWorker.continuity(predecessor, header)
    end

    test "accepts when node previousblockhash has trailing whitespace" do
      predecessor = %Block{hash: "0000000000000000158116981dd2a2b78eb0388662cbf30b856cf7188e76b7f2"}
      header = %{"previousblockhash" => "0000000000000000158116981dd2a2b78eb0388662cbf30b856cf7188e76b7f2\n"}
      assert :ok = SyncHeadersWorker.continuity(predecessor, header)
    end

    test "still rejects a genuine prevhash mismatch after normalization" do
      predecessor = %Block{hash: "0000000000000000158116981dd2a2b78eb0388662cbf30b856cf7188e76b7f2"}
      header = %{"previousblockhash" => "00000000000000000340fbae49ebbc6f63721b094f3d5a80d95f78d8b7440ce8"}
      assert {:error, :prevhash_mismatch} = SyncHeadersWorker.continuity(predecessor, header)
    end
  end

  describe "queue_transaction_fetch integration" do
    test "queuing tx fetch for a block transitions it to txs_queued" do
      block = block_fixture(%{
        height: 200,
        hash: "tx_test_hash",
        sync_state: "header_only"
      })

      assert {:ok, _job} = Chain.queue_transaction_fetch(block)

      updated = Chain.get_block!(200)
      assert updated.sync_state == "txs_queued"
    end

    test "defaults to the backfill lane" do
      block = block_fixture(%{height: 201, hash: "lane_default_hash", sync_state: "header_only"})

      assert {:ok, job} = Chain.queue_transaction_fetch(block)
      assert job.queue == "transactions_backfill"
    end

    test "lane: :tip routes to the tip lane with higher priority" do
      block = block_fixture(%{height: 202, hash: "lane_tip_hash", sync_state: "header_only"})

      assert {:ok, job} = Chain.queue_transaction_fetch(block, lane: :tip)
      assert job.queue == "transactions_tip"
      assert job.priority == 0
    end
  end
end
