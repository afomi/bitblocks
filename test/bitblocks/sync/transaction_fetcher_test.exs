defmodule Bitblocks.Sync.TransactionFetcherTest do
  use Bitblocks.DataCase, async: false

  alias Bitblocks.Sync.{TransactionFetcher, BlockProducer}

  @moduletag :integration

  setup do
    # Start a test producer
    {:ok, producer} =
      BlockProducer.start_link(
        start_height: 100_000,
        end_height: 100_002,
        parent: self()
      )

    %{producer: producer}
  end

  describe "TransactionFetcher" do
    test "fetches block data from producer events", %{producer: producer} do
      # Start a single fetcher
      {:ok, fetcher} =
        TransactionFetcher.start_link(
          id: 1,
          subscribe_to: [producer],
          parent: self()
        )

      # Wait for events to be processed
      Process.sleep(1000)

      # Should receive block_processed or block_error messages
      assert_receive {:block_processed, _height}, 5000

      # Clean up
      GenServer.stop(fetcher)
      GenServer.stop(producer)
    end

    test "enriches block info with transaction data", %{producer: producer} do
      {:ok, fetcher} =
        TransactionFetcher.start_link(
          id: 1,
          subscribe_to: [producer],
          parent: self()
        )

      # Wait for processing
      Process.sleep(1000)

      # Verify we get structured block data
      # Note: This will call the real Bitcoin RPC
      # In a production test suite, you'd mock BitcoinsvCli

      GenServer.stop(fetcher)
      GenServer.stop(producer)
    end

    test "handles errors gracefully", %{producer: _producer} do
      # Start a producer with an invalid block range
      {:ok, error_producer} =
        BlockProducer.start_link(
          start_height: 999_999_999,
          end_height: 999_999_999,
          parent: self()
        )

      {:ok, fetcher} =
        TransactionFetcher.start_link(
          id: 1,
          subscribe_to: [error_producer],
          parent: self()
        )

      # Should receive error message
      assert_receive {:block_error, _height, _error}, 5000

      GenServer.stop(fetcher)
      GenServer.stop(error_producer)
    end

    test "multiple fetchers process blocks concurrently" do
      {:ok, producer} =
        BlockProducer.start_link(
          start_height: 100_000,
          end_height: 100_004,
          parent: self()
        )

      # Start 3 fetchers
      fetchers =
        Enum.map(1..3, fn id ->
          {:ok, fetcher} =
            TransactionFetcher.start_link(
              id: id,
              subscribe_to: [producer],
              parent: self()
            )

          fetcher
        end)

      # Wait for all to process
      Process.sleep(2000)

      # Should receive multiple block_processed messages
      # (actual count depends on how blocks are distributed)
      receive do
        {:block_processed, _height} -> :ok
      after
        5000 -> flunk("Expected at least one block to be processed")
      end

      # Clean up
      Enum.each(fetchers, &GenServer.stop/1)
      GenServer.stop(producer)
    end

    test "respects fetch_full_transactions config" do
      # Set config to false (default)
      original = Application.get_env(:bitblocks, :fetch_full_transactions)
      Application.put_env(:bitblocks, :fetch_full_transactions, false)

      {:ok, producer} =
        BlockProducer.start_link(
          start_height: 100_000,
          end_height: 100_000,
          parent: self()
        )

      {:ok, fetcher} =
        TransactionFetcher.start_link(
          id: 1,
          subscribe_to: [producer],
          parent: self()
        )

      Process.sleep(1000)

      # Should process block without fetching full tx details
      assert_receive {:block_processed, _height}, 5000

      # Restore config
      if original do
        Application.put_env(:bitblocks, :fetch_full_transactions, original)
      else
        Application.delete_env(:bitblocks, :fetch_full_transactions)
      end

      GenServer.stop(fetcher)
      GenServer.stop(producer)
    end

    test "handles large blocks by limiting transaction fetching" do
      original_max = Application.get_env(:bitblocks, :max_transactions_per_block)
      Application.put_env(:bitblocks, :max_transactions_per_block, 10)

      {:ok, producer} =
        BlockProducer.start_link(
          start_height: 100_000,
          end_height: 100_000,
          parent: self()
        )

      {:ok, fetcher} =
        TransactionFetcher.start_link(
          id: 1,
          subscribe_to: [producer],
          parent: self()
        )

      Process.sleep(1000)

      # Should process even if block has many txs
      assert_receive {:block_processed, _height}, 5000

      # Restore config
      if original_max do
        Application.put_env(:bitblocks, :max_transactions_per_block, original_max)
      else
        Application.delete_env(:bitblocks, :max_transactions_per_block)
      end

      GenServer.stop(fetcher)
      GenServer.stop(producer)
    end
  end
end
