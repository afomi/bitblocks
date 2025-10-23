defmodule BitblocksWeb.TelemetryMetrics do
  @moduledoc """
  Telemetry metrics definitions for Bitblocks.

  This module defines metrics for monitoring:
  - Bitcoin RPC call latency and throughput
  - Blockchain sync pipeline performance
  - Database write performance
  - HTTP request metrics (Phoenix default)
  """

  use Supervisor
  import Telemetry.Metrics

  @rpc_batch_size_buckets [1, 5, 10, 25, 50, 100, 250, 500]
  @block_producer_blocks_buckets [1, 5, 10, 25, 50, 100, 250, 500]
  @transaction_fetch_duration_buckets [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 60_000]
  @transaction_fetch_tx_buckets [0, 1, 10, 50, 100, 250, 500, 1_000]
  @block_sync_duration_buckets [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 60_000]
  @block_sync_tx_buckets [0, 1, 10, 50, 100, 250, 500, 1_000]
  @database_writer_blocks_buckets [1, 5, 10, 25, 50, 100]

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix/HTTP Metrics
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        tags: [:route]
      ),
      summary("phoenix.router_dispatch.stop.duration",
        unit: {:native, :millisecond},
        tags: [:route]
      ),

      # Bitcoin RPC Metrics
      summary("bitblocks.bitcoin_rpc.call.duration",
        unit: {:native, :millisecond},
        description: "Duration of individual RPC calls",
        tags: [:method, :result],
        tag_values: fn metadata -> %{method: metadata.method, result: metadata.result} end
      ),
      counter("bitblocks.bitcoin_rpc.call.count",
        description: "Total number of RPC calls",
        tags: [:method, :result]
      ),
      summary("bitblocks.bitcoin_rpc.batch.duration",
        unit: {:native, :millisecond},
        description: "Duration of batch RPC calls",
        tags: [:method, :result],
        tag_values: fn metadata -> %{method: metadata.method, result: metadata.result} end
      ),
      distribution("bitblocks.bitcoin_rpc.batch.batch_size",
        description: "Number of requests in batch RPC calls",
        buckets: @rpc_batch_size_buckets,
        reporter_options: [buckets: @rpc_batch_size_buckets]
      ),
      counter("bitblocks.bitcoin_rpc.batch.count",
        description: "Total number of batch RPC calls",
        tags: [:method, :result]
      ),

      # Sync Pipeline - BlockProducer Metrics
      summary("bitblocks.sync.block_producer.duration",
        unit: {:native, :millisecond},
        description: "Time to produce a batch of block headers"
      ),
      distribution("bitblocks.sync.block_producer.blocks_produced",
        description: "Number of blocks produced per batch",
        buckets: @block_producer_blocks_buckets,
        reporter_options: [buckets: @block_producer_blocks_buckets]
      ),
      distribution("bitblocks.sync.block_producer.blocks_skipped",
        description: "Number of blocks skipped (already exist)",
        buckets: [0, 1, 5, 10, 25, 50, 100],
        reporter_options: [buckets: [0, 1, 5, 10, 25, 50, 100]]
      ),
      counter("bitblocks.sync.block_producer.total_blocks",
        description: "Total blocks produced",
        event_name: [:bitblocks, :sync, :block_producer],
        measurement: :blocks_produced
      ),
      distribution("bitblocks.sync.transaction_fetch.duration",
        unit: {:native, :millisecond},
        description: "Time to fetch and enrich a block within the transaction fetcher",
        tags: [:mode, :status],
        tag_values: fn metadata ->
          %{
            mode: metadata[:mode] || :unknown,
            status: metadata[:status] || :unknown
          }
        end,
        buckets: @transaction_fetch_duration_buckets,
        reporter_options: [buckets: @transaction_fetch_duration_buckets]
      ),
      distribution("bitblocks.sync.transaction_fetch.tx_count",
        description: "Transaction count processed per fetched block",
        buckets: @transaction_fetch_tx_buckets,
        reporter_options: [buckets: @transaction_fetch_tx_buckets]
      ),
      distribution("bitblocks.sync.block_sync.duration",
        unit: {:native, :millisecond},
        description: "End-to-end time to sync a single block in sequential mode",
        tags: [:mode, :status],
        tag_values: fn metadata ->
          %{
            mode: metadata[:mode] || :unknown,
            status: metadata[:status] || :unknown
          }
        end,
        buckets: @block_sync_duration_buckets,
        reporter_options: [buckets: @block_sync_duration_buckets]
      ),
      distribution("bitblocks.sync.block_sync.tx_count",
        description: "Transactions observed per sequentially synced block",
        buckets: @block_sync_tx_buckets,
        reporter_options: [buckets: @block_sync_tx_buckets]
      ),

      # Sync Pipeline - DatabaseWriter Metrics
      summary("bitblocks.sync.database_writer.duration",
        unit: {:native, :millisecond},
        description: "Time to write blocks to database"
      ),
      distribution("bitblocks.sync.database_writer.blocks_written",
        description: "Number of blocks written per batch",
        buckets: @database_writer_blocks_buckets,
        reporter_options: [buckets: @database_writer_blocks_buckets]
      ),
      counter("bitblocks.sync.database_writer.blocks_failed",
        description: "Number of failed block writes",
        event_name: [:bitblocks, :sync, :database_writer],
        measurement: :blocks_failed
      ),
      counter("bitblocks.sync.database_writer.total_blocks",
        description: "Total blocks written to database",
        event_name: [:bitblocks, :sync, :database_writer],
        measurement: :blocks_written
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :megabyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Database Metrics (Ecto)
      summary("bitblocks.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "Total time spent executing the query"
      ),
      summary("bitblocks.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "Time spent decoding query results"
      ),
      summary("bitblocks.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "Time spent executing query on database"
      ),
      summary("bitblocks.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "Time spent waiting for database connection"
      ),
      counter("bitblocks.repo.query.count",
        description: "Total number of database queries"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      {__MODULE__, :dispatch_stats, []}
    ]
  end

  def dispatch_stats do
    # Custom periodic measurements can be added here
    :ok
  end
end
