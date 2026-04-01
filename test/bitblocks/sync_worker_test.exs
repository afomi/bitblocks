defmodule Bitblocks.SyncWorkerTest do
  use Bitblocks.DataCase, async: false

  alias Bitblocks.SyncWorker
  alias Bitblocks.Chain.Block
  alias BitblocksWeb.RpcStub

  import Ecto.Query

  setup do
    # Stop any running Sync Worker
    case Process.whereis(SyncWorker) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          try do
            SyncWorker.stop_sync()
          catch
            :exit, _ -> :ok
          end

          Process.sleep(100)
          if Process.alive?(pid), do: Process.exit(pid, :kill)
          Process.sleep(50)
        end
    end

    # Start RpcStub for mocking RPC calls
    RpcStub.setup()

    # Clean up any existing test blocks
    from(b in Block, where: b.height >= 50_000 and b.height <= 50_200)
    |> Repo.delete_all()

    on_exit(fn ->
      RpcStub.clear()
    end)

    :ok
  end

  describe "sync_block/1 - block does not exist locally" do
    test "makes RPC calls and returns block when block doesn't exist" do
      block_height = 50_000
      block_hash = "0000000000000000000000000000000000000000000000000000000000050000"

      # Verify block doesn't exist
      assert Repo.get_by(Block, height: block_height) == nil

      # Stub the RPC responses
      RpcStub.stub_getblockhash(block_height, block_hash)

      RpcStub.stub_getblock(block_hash, 1, %{
        "hash" => block_hash,
        "confirmations" => 100,
        "size" => 1_234_567,
        "height" => block_height,
        "version" => 1,
        "merkleroot" => "abc123def456abc123def456abc123def456abc123def456abc123def456abc1",
        "num_tx" => 150,
        "tx" => [
          "tx1111111111111111111111111111111111111111111111111111111111111111",
          "tx2222222222222222222222222222222222222222222222222222222222222222",
          "tx3333333333333333333333333333333333333333333333333333333333333333"
        ],
        "time" => 1_704_067_200,
        "mediantime" => 1_704_067_100,
        "nonce" => 987_654_321,
        "bits" => "1a0fffff",
        "difficulty" => "123456.789",
        "chainwork" => "0000000000000000000000000000000000000000000000000000000000999999",
        "previousblockhash" => "0000000000000000000000000000000000000000000000000000000000049999",
        "nextblockhash" => "0000000000000000000000000000000000000000000000000000000000050001"
      })

      # Start a sync worker (handle if already started)
      worker_pid =
        case SyncWorker.start_link(scope: {:range, block_height, block_height}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      # Give the worker access to the sandbox
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker_pid)

      # Wait for sync to complete
      wait_for_sync_completion(worker_pid, 5_000)

      # Verify block was inserted
      block = Repo.get_by(Block, height: block_height)
      assert block != nil
      assert block.hash == block_hash
      assert block.height == block_height
      assert block.num_tx == 150

      assert block.merkleroot ==
               "abc123def456abc123def456abc123def456abc123def456abc123def456abc1"

      assert block.size == 1_234_567
      assert block.difficulty == "123456.789"
      assert length(block.tx) == 3
    end

    test "handles large blocks by not storing tx array (>10k txs)" do
      block_height = 50_001
      block_hash = "0000000000000000000000000000000000000000000000000000000000050001"

      # Generate a large tx array (>10k transactions)
      large_tx_list =
        Enum.map(1..15_000, fn i ->
          String.duplicate("#{rem(i, 10)}", 64)
        end)

      # Stub the RPC responses
      RpcStub.stub_getblockhash(block_height, block_hash)

      RpcStub.stub_getblock(block_hash, 1, %{
        "hash" => block_hash,
        "confirmations" => 100,
        "size" => 250_000_000,
        "height" => block_height,
        "version" => 1,
        "merkleroot" => "large123def456abc123def456abc123def456abc123def456abc123def456abc1",
        "num_tx" => 15_000,
        "tx" => large_tx_list,
        "time" => 1_704_067_300,
        "mediantime" => 1_704_067_200,
        "nonce" => 111_222_333,
        "bits" => "1a0fffff",
        "difficulty" => "123456.789",
        "chainwork" => "0000000000000000000000000000000000000000000000000000000000888888",
        "previousblockhash" => "0000000000000000000000000000000000000000000000000000000000050000"
      })

      # Start a sync worker (handle if already started)
      worker_pid =
        case SyncWorker.start_link(scope: {:range, block_height, block_height}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      # Give the worker access to the sandbox
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker_pid)

      # Wait for sync to complete
      wait_for_sync_completion(worker_pid, 5_000)

      # Verify block was inserted
      block = Repo.get_by(Block, height: block_height)
      assert block != nil
      assert block.hash == block_hash
      assert block.num_tx == 15_000

      # Verify tx array is empty (memory optimization)
      assert block.tx == []
    end

    test "handles RPC errors gracefully" do
      block_height = 50_002
      block_hash = "0000000000000000000000000000000000000000000000000000000000050002"

      # Stub getblockhash to succeed
      RpcStub.stub_getblockhash(block_height, block_hash)

      # Stub getblock to fail
      RpcStub.stub_getblock(block_hash, 1, {:error, "Block not found"})

      # Start a sync worker (handle if already started)
      worker_pid =
        case SyncWorker.start_link(scope: {:range, block_height, block_height}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      # Give the worker access to the sandbox
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker_pid)

      # Wait for sync to complete (should fail but not crash)
      wait_for_sync_completion(worker_pid, 5_000)

      # Verify block was NOT inserted
      block = Repo.get_by(Block, height: block_height)
      assert block == nil

      # Verify worker tracked the error
      status = SyncWorker.get_status()
      assert status.errors_count > 0
    end
  end

  describe "sync_block/1 - block exists locally" do
    test "no RPC call is made when block already exists" do
      block_height = 50_003
      block_hash = "0000000000000000000000000000000000000000000000000000000000050003"

      # Pre-insert the block
      {:ok, _existing_block} =
        %Block{
          height: block_height,
          hash: block_hash,
          merkleroot: "existing123456789",
          num_tx: 50,
          tx: ["existing_tx1", "existing_tx2"],
          time: 1_704_067_000,
          mediantime: 1_704_066_900,
          nonce: 111_111_111,
          bits: "1a0fffff",
          difficulty: "111.222",
          chainwork: "0000000000000000000000000000000000000000000000000000000000777777",
          size: 500_000,
          version: 1,
          prevblockhash: "0000000000000000000000000000000000000000000000000000000000050002",
          sync_state: "header_synced"
        }
        |> Repo.insert()

      # Clear RPC stubs - we want to ensure NO RPC calls are made
      RpcStub.clear()

      # Start a sync worker for this block (handle if already started)
      worker_pid =
        case SyncWorker.start_link(scope: {:range, block_height, block_height}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      # Give the worker access to the sandbox
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker_pid)

      # Wait for sync to complete
      wait_for_sync_completion(worker_pid, 5_000)

      # Verify block still exists with original data (not fetched from RPC)
      block = Repo.get_by(Block, height: block_height)
      assert block != nil
      assert block.hash == block_hash
      assert block.merkleroot == "existing123456789"
      assert block.num_tx == 50

      # Verify sync completed without errors (no RPC calls needed)
      status = SyncWorker.get_status()
      assert status.status in [:completed, :stopped]
      assert status.blocks_synced == 0
    end

    test "syncs multiple blocks, only fetches missing ones" do
      # Set up: blocks 50_004, 50_005, 50_006
      # Pre-insert 50_004 and 50_006 (50_005 is missing)
      {:ok, _block1} =
        %Block{
          height: 50_004,
          hash: "0000000000000000000000000000000000000000000000000000000000050004",
          merkleroot: "block50004",
          num_tx: 10,
          tx: [],
          time: 1_704_067_400,
          mediantime: 1_704_067_300,
          nonce: 444_444_444,
          bits: "1a0fffff",
          difficulty: "100.0",
          chainwork: "0000000000000000000000000000000000000000000000000000000000666666",
          size: 100_000,
          version: 1,
          sync_state: "header_synced"
        }
        |> Repo.insert()

      {:ok, _block3} =
        %Block{
          height: 50_006,
          hash: "0000000000000000000000000000000000000000000000000000000000050006",
          merkleroot: "block50006",
          num_tx: 10,
          tx: [],
          time: 1_704_067_600,
          mediantime: 1_704_067_500,
          nonce: 666_666_666,
          bits: "1a0fffff",
          difficulty: "100.0",
          chainwork: "0000000000000000000000000000000000000000000000000000000000444444",
          size: 100_000,
          version: 1,
          sync_state: "header_synced"
        }
        |> Repo.insert()

      # Stub RPC only for the missing block (50_005)
      missing_height = 50_005
      missing_hash = "0000000000000000000000000000000000000000000000000000000000050005"

      RpcStub.stub_getblockhash(missing_height, missing_hash)

      RpcStub.stub_getblock(missing_hash, 1, %{
        "hash" => missing_hash,
        "confirmations" => 100,
        "size" => 100_000,
        "height" => missing_height,
        "version" => 1,
        "merkleroot" => "block50005",
        "num_tx" => 10,
        "tx" => ["tx_for_50005"],
        "time" => 1_704_067_500,
        "mediantime" => 1_704_067_400,
        "nonce" => 555_555_555,
        "bits" => "1a0fffff",
        "difficulty" => "100.0",
        "chainwork" => "0000000000000000000000000000000000000000000000000000000000555555",
        "previousblockhash" => "0000000000000000000000000000000000000000000000000000000000050004",
        "nextblockhash" => "0000000000000000000000000000000000000000000000000000000000050006"
      })

      # Start sync for all three blocks (handle if already started)
      worker_pid =
        case SyncWorker.start_link(scope: {:range, 50_004, 50_006}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      # Give the worker access to the sandbox
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker_pid)

      # Wait for sync to complete
      wait_for_sync_completion(worker_pid, 5_000)

      # Verify all three blocks exist
      block1 = Repo.get_by(Block, height: 50_004)
      block2 = Repo.get_by(Block, height: 50_005)
      block3 = Repo.get_by(Block, height: 50_006)

      assert block1 != nil
      assert block2 != nil
      assert block3 != nil

      # Verify only block2 was fetched (has new data)
      assert block1.merkleroot == "block50004"
      assert block2.merkleroot == "block50005"
      assert block3.merkleroot == "block50006"

      # Verify only 1 block was synced (the missing one)
      status = SyncWorker.get_status()
      assert status.blocks_synced == 1
    end
  end

  describe "lazy mode batch discovery" do
    test "continues through batches even when first batch is complete" do
      # Pre-insert blocks 50_007 through 50_106 (first batch of 100)
      for height <- 50_007..50_106 do
        %Block{
          height: height,
          hash: String.pad_leading(Integer.to_string(height), 64, "0"),
          merkleroot: "existing_#{height}",
          num_tx: 5,
          tx: [],
          time: 1_704_067_000 + height,
          mediantime: 1_704_066_900 + height,
          nonce: height,
          bits: "1a0fffff",
          difficulty: "100.0",
          chainwork: String.pad_leading(Integer.to_string(height), 64, "0"),
          size: 100_000,
          version: 1,
          sync_state: "header_synced"
        }
        |> Repo.insert!()
      end

      # Stub RPC for block 50_107 (second batch, first missing block)
      missing_height = 50_107
      missing_hash = "0000000000000000000000000000000000000000000000000000000000050107"

      RpcStub.stub_getblockhash(missing_height, missing_hash)

      RpcStub.stub_getblock(missing_hash, 1, %{
        "hash" => missing_hash,
        "confirmations" => 100,
        "size" => 100_000,
        "height" => missing_height,
        "version" => 1,
        "merkleroot" => "new_block_50107",
        "num_tx" => 20,
        "tx" => ["tx_50107"],
        "time" => 1_704_067_000 + missing_height,
        "mediantime" => 1_704_066_900 + missing_height,
        "nonce" => 999_999_999,
        "bits" => "1a0fffff",
        "difficulty" => "100.0",
        "chainwork" => String.pad_leading(Integer.to_string(missing_height), 64, "0"),
        "previousblockhash" => String.pad_leading(Integer.to_string(missing_height - 1), 64, "0")
      })

      # Start sync from 50_007 to 50_200 (should use lazy mode) (handle if already started)
      worker_pid =
        case SyncWorker.start_link(scope: {:from_block, 50_007}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      # Give the worker access to the sandbox
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker_pid)

      # Wait for sync to discover and fetch the missing block
      wait_for_sync_completion(worker_pid, 10_000)

      # Verify block 50_107 was fetched
      block = Repo.get_by(Block, height: missing_height)
      assert block != nil
      assert block.merkleroot == "new_block_50107"

      # Verify at least 1 block was synced
      status = SyncWorker.get_status()
      assert status.blocks_synced >= 1
    end
  end

  # Helper functions

  defp wait_for_sync_completion(_pid, timeout) do
    start_time = System.monotonic_time(:millisecond)

    wait_loop = fn wait_loop_fn ->
      status = SyncWorker.get_status()
      elapsed = System.monotonic_time(:millisecond) - start_time

      cond do
        status.status in [:completed, :stopped] ->
          :ok

        elapsed > timeout ->
          :timeout

        true ->
          Process.sleep(100)
          wait_loop_fn.(wait_loop_fn)
      end
    end

    wait_loop.(wait_loop)
  end
end
