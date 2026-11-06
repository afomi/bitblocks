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

  describe "reopen_short_blocks/3" do
    defp short_block(height, state \\ "completed") do
      block_fixture(%{height: height, hash: "short_#{height}", num_tx: 2, sync_state: state})
    end

    test "a dry run reports the short blocks and changes nothing" do
      block = short_block(700_020)
      transaction_fixture(%{block_hash: block.hash})

      {report, io} = with_io(fn -> Release.reopen_short_blocks(700_000, 700_100) end)

      assert %{applied: false, short: 1, rows_missing: 1, reopened: 0} = report
      assert %{lowest: 700_020, highest: 700_020} = report
      assert io =~ "(dry run)"
      assert Repo.reload!(block).sync_state == "completed"
    end

    test "apply reopens short completed blocks, and leaves other states to the loop" do
      short = short_block(700_020)
      failed = short_block(700_021, "failed")

      {report, _io} =
        with_io(fn -> Release.reopen_short_blocks(700_000, 700_100, apply: true) end)

      assert %{short: 1, reopened: 1} = report
      assert %{sync_state: "header_synced", tx_sync_completed_at: nil} = Repo.reload!(short)
      assert Repo.reload!(failed).sync_state == "failed"
      assert Repo.all(Oban.Job) == []
    end

    test "leaves a block with all its rows, and blocks outside the range" do
      whole = block_fixture(%{height: 700_023, hash: "whole", num_tx: 1, sync_state: "completed"})
      transaction_fixture(%{block_hash: whole.hash})
      outside = short_block(700_200)

      {report, _io} =
        with_io(fn -> Release.reopen_short_blocks(700_000, 700_100, apply: true) end)

      assert %{examined: 1, short: 0, reopened: 0} = report
      assert Repo.reload!(whole).sync_state == "completed"
      assert Repo.reload!(outside).sync_state == "completed"
    end

    test "never reopens the heights short by design" do
      blocks =
        for height <- [0, 91_722, 91_812] do
          block_fixture(%{height: height, hash: "design_#{height}", sync_state: "completed"})
          |> Ecto.Changeset.change(num_tx: 2)
          |> Repo.update!()
        end

      {report, _io} = with_io(fn -> Release.reopen_short_blocks(0, 100_000, apply: true) end)

      assert %{examined: 0, reopened: 0} = report
      assert Enum.all?(blocks, &(Repo.reload!(&1).sync_state == "completed"))
    end

    test "walks past a batch of whole blocks to a short one" do
      for height <- 700_300..700_810 do
        block_fixture(%{height: height, hash: "b#{height}", num_tx: 0, sync_state: "completed"})
      end

      short = short_block(700_900)

      {report, _io} =
        with_io(fn -> Release.reopen_short_blocks(700_300, 700_900, apply: true) end)

      assert %{examined: 512, short: 1, reopened: 1} = report
      assert Repo.reload!(short).sync_state == "header_synced"
    end
  end

  describe "sync_status/0" do
    test "prints complete_through, the known tip and the target" do
      block_fixture(%{height: 0, num_tx: 1, sync_state: "completed"})
      block_fixture(%{height: 1, num_tx: 1, sync_state: "failed"})

      {result, io} = with_io(fn -> Release.sync_status() end)

      assert %{complete_through: 0, tip: 1, target: 1} = result
      assert io =~ "Complete through block 0 (of 1 known)"
      assert io =~ "Target: block 1 (failed"
    end
  end
end
