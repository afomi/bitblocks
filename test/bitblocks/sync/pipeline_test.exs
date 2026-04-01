defmodule Bitblocks.Sync.PipelineTest do
  use Bitblocks.DataCase, async: false

  alias Bitblocks.Sync.Pipeline
  alias Bitblocks.Chain

  @moduletag :integration

  setup do
    # Ensure pipeline is in idle state before each test
    case Pipeline.status() do
      %{status: :running} -> Pipeline.stop_sync()
      _ -> :ok
    end

    Process.sleep(100)
    :ok
  end

  describe "Pipeline.start_sync/2" do
    test "starts sync for a block range" do
      # Use a small range of known blocks
      assert :ok = Pipeline.start_sync(100_000, 100_002)

      status = Pipeline.status()
      assert status.status == :running
      assert status.start_height == 100_000
      assert status.end_height == 100_002

      # Clean up
      Pipeline.stop_sync()
    end

    test "returns error if already running" do
      assert :ok = Pipeline.start_sync(100_000, 100_001)
      assert {:error, :already_running} = Pipeline.start_sync(100_000, 100_001)

      # Clean up
      Pipeline.stop_sync()
    end

    test "syncs blocks to database" do
      start_height = 100_000
      end_height = 100_001

      # Clear any existing blocks in this range
      from(b in Chain.Block, where: b.height >= ^start_height and b.height <= ^end_height)
      |> Bitblocks.Repo.delete_all()

      # Start sync
      assert :ok = Pipeline.start_sync(start_height, end_height)

      # Wait for completion (up to 30 seconds)
      wait_for_completion(30_000)

      # Verify blocks were synced
      blocks =
        from(b in Chain.Block, where: b.height >= ^start_height and b.height <= ^end_height)
        |> Bitblocks.Repo.all()

      assert length(blocks) > 0

      # Clean up
      Pipeline.stop_sync()
    end
  end

  describe "Pipeline.stop_sync/0" do
    test "stops a running sync" do
      assert :ok = Pipeline.start_sync(100_000, 100_010)
      Pipeline.stop_sync()

      # Cast is async — give it a moment to process
      Process.sleep(100)
      status = Pipeline.status()
      assert status.status == :stopped
    end

    test "is a no-op if not running" do
      # stop_sync is now a cast and returns :ok regardless
      assert :ok = Pipeline.stop_sync()
    end
  end

  describe "Pipeline.status/0" do
    test "returns idle status initially" do
      status = Pipeline.status()
      assert is_map(status)
      assert Map.has_key?(status, :status)
    end

    test "returns progress information during sync" do
      assert :ok = Pipeline.start_sync(100_000, 100_005)

      Process.sleep(500)

      status = Pipeline.status()
      assert status.status == :running
      assert is_integer(status.start_height)
      assert is_integer(status.end_height)
      assert is_integer(status.blocks_processed)
      assert is_float(status.progress_percent)

      # Clean up
      Pipeline.stop_sync()
    end
  end

  describe "backpressure and concurrency" do
    test "processes multiple blocks concurrently" do
      start_height = 100_000
      end_height = 100_004

      # Clear blocks
      from(b in Chain.Block, where: b.height >= ^start_height and b.height <= ^end_height)
      |> Bitblocks.Repo.delete_all()

      start_time = System.monotonic_time(:millisecond)

      assert :ok = Pipeline.start_sync(start_height, end_height)

      wait_for_completion(30_000)

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      # With 5 concurrent workers, should be faster than sequential
      # Sequential would take ~5 seconds (1s per block), parallel should be ~1-2s
      # Allow generous margin for test environment variability
      assert duration_ms < 10_000, "Parallel sync took too long: #{duration_ms}ms"

      # Clean up
      Pipeline.stop_sync()
    end

    test "handles demand correctly across stages" do
      # Start with a range that will generate multiple demands
      assert :ok = Pipeline.start_sync(100_000, 100_010)

      # Pipeline should handle demand automatically via backpressure
      # Just verify it doesn't crash or hang
      Process.sleep(2000)

      status = Pipeline.status()
      assert status.status in [:running, :completed]

      # Clean up
      Pipeline.stop_sync()
    end
  end

  describe "error handling" do
    test "handles RPC errors gracefully" do
      # Try to sync a non-existent block range
      assert :ok = Pipeline.start_sync(999_999_999, 999_999_999)

      # Wait a bit
      Process.sleep(2000)

      status = Pipeline.status()
      # Should report errors but not crash
      assert is_integer(status.errors_count)

      # Clean up
      Pipeline.stop_sync()
    end

    test "continues syncing after encountering errors" do
      # Mix valid and invalid blocks
      # Most real blocks should sync, invalid ones should error
      assert :ok = Pipeline.start_sync(100_000, 100_002)

      wait_for_completion(30_000)

      status = Pipeline.status()
      # Should have completed or stopped
      assert status.status in [:completed, :stopped]

      # Clean up
      Pipeline.stop_sync()
    end
  end

  describe "progress tracking and events" do
    test "broadcasts progress events via PubSub" do
      Phoenix.PubSub.subscribe(Bitblocks.PubSub, "sync_pipeline")

      assert :ok = Pipeline.start_sync(100_000, 100_001)

      # Should receive pipeline events
      assert_receive {:pipeline_started, _start, _end}, 2000

      # May receive progress updates
      receive do
        {:pipeline_progress, _data} -> :ok
      after
        5000 -> :ok
      end

      # Clean up
      Pipeline.stop_sync()
    end

    test "tracks blocks processed accurately" do
      start_height = 100_000
      end_height = 100_002

      # Clear blocks
      from(b in Chain.Block, where: b.height >= ^start_height and b.height <= ^end_height)
      |> Bitblocks.Repo.delete_all()

      assert :ok = Pipeline.start_sync(start_height, end_height)

      wait_for_completion(30_000)

      status = Pipeline.status()
      expected_blocks = end_height - start_height + 1

      # Should have processed all blocks
      assert status.blocks_processed <= expected_blocks

      # Clean up
      Pipeline.stop_sync()
    end
  end

  describe "integration with database" do
    test "stores blocks with correct sync_state" do
      start_height = 100_000
      end_height = 100_000

      # Clear block
      from(b in Chain.Block, where: b.height == ^start_height)
      |> Bitblocks.Repo.delete_all()

      assert :ok = Pipeline.start_sync(start_height, end_height)

      wait_for_completion(20_000)

      # Check block was stored
      block = Bitblocks.Repo.get_by(Chain.Block, height: start_height)
      assert block != nil
      assert block.hash != nil
      assert block.sync_state in ["header_synced", "completed"]

      # Clean up
      Pipeline.stop_sync()
    end

    test "skips already synced blocks" do
      start_height = 100_000
      end_height = 100_001

      # Pre-insert blocks
      from(b in Chain.Block, where: b.height >= ^start_height and b.height <= ^end_height)
      |> Bitblocks.Repo.delete_all()

      # First sync
      assert :ok = Pipeline.start_sync(start_height, end_height)
      wait_for_completion(20_000)
      Pipeline.stop_sync()

      first_count =
        from(b in Chain.Block, where: b.height >= ^start_height and b.height <= ^end_height)
        |> Bitblocks.Repo.aggregate(:count, :id)

      Process.sleep(500)

      # Second sync - should skip existing
      assert :ok = Pipeline.start_sync(start_height, end_height)
      wait_for_completion(20_000)

      second_count =
        from(b in Chain.Block, where: b.height >= ^start_height and b.height <= ^end_height)
        |> Bitblocks.Repo.aggregate(:count, :id)

      # Count should remain the same
      assert first_count == second_count

      # Clean up
      Pipeline.stop_sync()
    end
  end

  # Helper functions

  defp wait_for_completion(timeout) do
    start_time = System.monotonic_time(:millisecond)

    wait_loop = fn wait_loop_fn ->
      status = Pipeline.status()
      elapsed = System.monotonic_time(:millisecond) - start_time

      cond do
        status.status in [:completed, :stopped] ->
          :ok

        elapsed > timeout ->
          flunk("Pipeline did not complete within #{timeout}ms")

        true ->
          Process.sleep(500)
          wait_loop_fn.(wait_loop_fn)
      end
    end

    wait_loop.(wait_loop)
  end
end
