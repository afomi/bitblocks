defmodule Bitblocks.ReleaseAuditTest do
  use Bitblocks.DataCase

  import Bitblocks.ChainFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.Release

  describe "audit_completeness/1" do
    test "flags a completed block whose stored tx rows fall short of num_tx" do
      # The silent-incompleteness case: sync_state says done, the table disagrees.
      block =
        block_fixture(%{
          height: 700_001,
          hash: "audit_deficit_completed",
          num_tx: 3,
          tx: [],
          sync_state: "completed"
        })

      transaction_fixture(%{block_hash: block.hash})

      {result, _io} = with_io(fn -> Release.audit_completeness() end)

      assert %{count: 1, deficits: [deficit]} = result
      assert deficit.hash == block.hash
      assert deficit.sync_state == "completed"
      assert deficit.stored == 1
      assert deficit.missing == 2
    end

    test "does not flag a block whose transactions are all stored" do
      block =
        block_fixture(%{
          height: 700_002,
          hash: "audit_full_block",
          num_tx: 1,
          sync_state: "completed"
        })

      transaction_fixture(%{block_hash: block.hash})

      {result, _io} = with_io(fn -> Release.audit_completeness() end)

      assert result.count == 0
    end

    test "flags a header-only block with no rows (num_tx unknown still implies a coinbase)" do
      block_fixture(%{
        height: 700_003,
        hash: "audit_header_only",
        num_tx: 0,
        sync_state: "header_only"
      })

      {result, _io} = with_io(fn -> Release.audit_completeness() end)

      assert %{count: 1, deficits: [%{sync_state: "header_only", missing: 1}]} = result
    end

    test "respects the limit option" do
      for i <- 1..3 do
        block_fixture(%{height: 700_010 + i, hash: "audit_limit_#{i}", num_tx: 2})
      end

      {result, _io} = with_io(fn -> Release.audit_completeness(limit: 2) end)

      assert result.count == 2
    end
  end

  describe "repair_incomplete_blocks/1" do
    test "resets deficit blocks across all states and starts the sequential backfill" do
      completed_deficit =
        block_fixture(%{
          height: 700_020,
          hash: "repair_completed",
          num_tx: 2,
          sync_state: "completed"
        })

      orphaned_queued =
        block_fixture(%{
          height: 700_021,
          hash: "repair_queued_orphan",
          num_tx: 1,
          sync_state: "txs_queued"
        })

      {result, _io} = with_io(fn -> Release.repair_incomplete_blocks() end)

      assert {:ok, %{reset: 2, skipped_active: 0}} = result
      assert Repo.reload!(completed_deficit).sync_state == "header_synced"
      assert Repo.reload!(orphaned_queued).sync_state == "header_synced"

      # Exactly one sequential backfill job was enqueued — no per-block flood.
      backfill_jobs =
        Repo.all(
          from(j in Oban.Job,
            where: j.worker == "Bitblocks.Workers.BackfillTransactionsWorker",
            where: j.state == "available"
          )
        )

      assert length(backfill_jobs) == 1
    end

    test "skips a deficit block that has a live fetch job" do
      block =
        block_fixture(%{
          height: 700_022,
          hash: "repair_active_job",
          num_tx: 1,
          sync_state: "txs_queued"
        })

      Repo.insert!(%Oban.Job{
        worker: "Bitblocks.Workers.FetchTransactionsWorker",
        queue: "transactions_backfill",
        state: "available",
        args: %{"block_hash" => block.hash}
      })

      {result, _io} = with_io(fn -> Release.repair_incomplete_blocks() end)

      assert {:ok, %{reset: 0, skipped_active: 1}} = result
      assert Repo.reload!(block).sync_state == "txs_queued"
    end

    test "is a no-op when the audit is clean" do
      block = block_fixture(%{height: 700_023, hash: "repair_clean", num_tx: 1})
      transaction_fixture(%{block_hash: block.hash})

      {result, _io} = with_io(fn -> Release.repair_incomplete_blocks() end)

      assert {:ok, %{reset: 0, skipped_active: 0}} = result

      assert Repo.all(
               from(j in Oban.Job,
                 where: j.worker == "Bitblocks.Workers.BackfillTransactionsWorker"
               )
             ) == []
    end
  end
end
