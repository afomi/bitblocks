defmodule Bitblocks.SyncWorkerTest do
  use Bitblocks.DataCase, async: false
  use ExVCR.Mock, adapter: ExVCR.Adapter.Hackney

  alias Bitblocks.SyncWorker
  alias Bitblocks.Chain.Block

  import Ecto.Query

  # Start an unnamed, isolated worker for each test to avoid
  # interference with the app-supervised named SyncWorker.
  setup do
    setup_bitcoin_rpc()

    from(b in Block, where: b.height >= 50_000 and b.height <= 51_200)
    |> Repo.delete_all()

    {:ok, worker} = SyncWorker.start_link(name: nil)
    ref = Process.monitor(worker)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker)

    on_exit(fn ->
      if Process.alive?(worker) do
        try do
          SyncWorker.stop_sync(worker)
        catch
          :exit, _ -> :ok
        end

        Process.exit(worker, :shutdown)
      end

      receive do
        {:DOWN, ^ref, :process, ^worker, _} -> :ok
      after
        500 -> :ok
      end

    end)

    {:ok, worker: worker}
  end

  describe "sync_block/1 - block does not exist locally" do
    test "makes RPC calls and returns block when block doesn't exist", %{worker: worker} do
      use_cassette "sync_worker/getblockhash_50000_and_header" do
        block_height = 50_000

        assert Repo.get_by(Block, height: block_height) == nil

        SyncWorker.start_sync({block_height, block_height}, worker)
        wait_for_sync_completion(worker, 5_000)

        block = Repo.get_by(Block, height: block_height)
        assert block != nil
        assert block.height == block_height
        assert is_binary(block.hash)
        assert is_integer(block.num_tx)
        assert block.tx == []
      end
    end

    test "handles large blocks by not storing tx array (>10k txs)", %{worker: worker} do
      use_cassette "sync_worker/getblockhash_and_header_large_block" do
        # Block 760000 has 10,284 transactions on BSV mainnet (just over the 10k threshold).
        block_height = 760_000

        SyncWorker.start_sync({block_height, block_height}, worker)
        wait_for_sync_completion(worker, 5_000)

        block = Repo.get_by(Block, height: block_height)
        assert block != nil
        assert block.tx == []
      end
    end

    test "handles RPC errors gracefully", %{worker: worker} do
      use_cassette "sync_worker/getblockhash_returns_error" do
        # This cassette records a getblockhash response for a height that
        # does not yet exist on the node (returns RPC error -8).
        block_height = 999_999_999

        SyncWorker.start_sync({block_height, block_height}, worker)
        wait_for_sync_completion(worker, 5_000)

        assert Repo.get_by(Block, height: block_height) == nil

        status = SyncWorker.get_status(worker)
        assert status.errors_count > 0
      end
    end
  end

  describe "sync_block/1 - block exists locally" do
    test "no RPC call is made when block already exists", %{worker: worker} do
      block_height = 50_003
      block_hash = "0000000000000000000000000000000000000000000000000000000000050003"

      {:ok, _} =
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

      # No cassette — no HTTP calls should be made for an already-synced block.
      SyncWorker.start_sync({block_height, block_height}, worker)
      wait_for_sync_completion(worker, 5_000)

      block = Repo.get_by(Block, height: block_height)
      assert block != nil
      assert block.hash == block_hash
      assert block.merkleroot == "existing123456789"
      assert block.num_tx == 50

      status = SyncWorker.get_status(worker)
      assert status.status in [:completed, :stopped]
      assert status.blocks_synced == 0
    end

    test "syncs multiple blocks, only fetches missing ones", %{worker: worker} do
      use_cassette "sync_worker/sync_range_50004_to_50006_missing_50005" do
        {:ok, _} =
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

        {:ok, _} =
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

        SyncWorker.start_sync({50_004, 50_006}, worker)
        wait_for_sync_completion(worker, 5_000)

        block1 = Repo.get_by(Block, height: 50_004)
        block2 = Repo.get_by(Block, height: 50_005)
        block3 = Repo.get_by(Block, height: 50_006)

        assert block1 != nil
        assert block2 != nil
        assert block3 != nil

        assert block1.merkleroot == "block50004"
        assert is_binary(block2.merkleroot)
        assert block3.merkleroot == "block50006"

        status = SyncWorker.get_status(worker)
        assert status.blocks_synced == 1
      end
    end
  end

  describe "lazy mode batch discovery" do
    test "continues through batches even when first batch is complete", %{worker: worker} do
      use_cassette "sync_worker/lazy_mode_batch_50007_to_51200" do
        # Pre-populate all blocks except 50107, so the worker only needs to sync that one.
        for height <- Enum.concat(50_007..50_106, 50_108..51_200) do
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

        # Range >1000 triggers lazy mode; cassette covers first missing batch (50107+).
        SyncWorker.start_sync({50_007, 51_200}, worker)
        wait_for_sync_completion(worker, 15_000)

        # At minimum, blocks immediately after the pre-populated range were synced.
        block = Repo.get_by(Block, height: 50_107)
        assert block != nil

        status = SyncWorker.get_status(worker)
        assert status.blocks_synced >= 1
      end
    end
  end

  defp wait_for_sync_completion(worker, timeout) do
    start_time = System.monotonic_time(:millisecond)

    wait_loop = fn wait_loop_fn ->
      status = SyncWorker.get_status(worker)
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
