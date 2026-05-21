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
  end
end
