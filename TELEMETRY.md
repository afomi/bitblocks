## Telemetry & Monitoring

This document describes the telemetry instrumentation and metrics available in Bitblocks for monitoring performance and latency.

## Overview

Bitblocks emits telemetry events for:
1. **Bitcoin RPC calls** - Individual and batch RPC latency
2. **Sync Pipeline** - Block producer and database writer performance
3. **Phoenix/HTTP** - Web request metrics
4. **Database** - Ecto query performance
5. **VM** - Erlang VM health metrics

## Accessing Metrics

### LiveDashboard

In development, visit:
```
http://localhost:4000/dev/dashboard
```

In production (requires admin auth):
```
https://your-app.fly.dev/dev/dashboard
```

Navigate to the **Metrics** tab to see real-time charts.

## Available Metrics

### Bitcoin RPC Metrics

#### Individual RPC Calls
- **Event:** `[:bitblocks, :bitcoin_rpc, :call]`
- **Measurements:**
  - `duration` - Time to complete RPC call (milliseconds)
- **Metadata:**
  - `method` - RPC method name (e.g., "getblockhash", "getblock")
  - `result` - `:ok` or `:error`

**Dashboard Metrics:**
- `bitblocks.bitcoin_rpc.call.duration` - Summary of call latency by method
- `bitblocks.bitcoin_rpc.call.count` - Total calls by method and result

**Example Usage:**
```elixir
# This call will emit telemetry
hash = BitcoinsvCli.getblockhash(12345)
```

#### Batch RPC Calls
- **Event:** `[:bitblocks, :bitcoin_rpc, :batch]`
- **Measurements:**
  - `duration` - Time to complete batch call (milliseconds)
  - `batch_size` - Number of requests in the batch
- **Metadata:**
  - `method` - Primary method name
  - `result` - `:ok` or `:error`

**Dashboard Metrics:**
- `bitblocks.bitcoin_rpc.batch.duration` - Summary of batch call latency
- `bitblocks.bitcoin_rpc.batch.batch_size` - Distribution of batch sizes

**Example Usage:**
```elixir
# This will emit telemetry with batch_size=100
{:ok, hashes} = BitcoinsvCli.batch_getblockhash(0..99)
```

### Sync Pipeline Metrics

#### BlockProducer
- **Event:** `[:bitblocks, :sync, :block_producer]`
- **Measurements:**
  - `duration` - Time to fetch block hashes (milliseconds)
  - `blocks_produced` - Number of new blocks fetched
  - `blocks_skipped` - Number of existing blocks skipped
- **Metadata:**
  - `start_height` - First block height in batch
  - `end_height` - Last block height in batch

**Dashboard Metrics:**
- `bitblocks.sync.block_producer.duration` - Time per batch
- `bitblocks.sync.block_producer.blocks_produced` - Distribution of batch sizes
- `bitblocks.sync.block_producer.total_blocks` - Total blocks produced (counter)

**What to Watch:**
- **High duration** - Network latency to Bitcoin node
- **Low blocks_produced** - Most blocks already synced (normal near chain tip)
- **High duration + low batch_size** - Consider increasing concurrency

#### DatabaseWriter
- **Event:** `[:bitblocks, :sync, :database_writer]`
- **Measurements:**
  - `duration` - Time to write blocks to database (milliseconds)
  - `blocks_written` - Number successfully written
  - `blocks_failed` - Number that failed to write
- **Metadata:**
  - `total_blocks` - Cumulative total blocks written

**Dashboard Metrics:**
- `bitblocks.sync.database_writer.duration` - Write latency
- `bitblocks.sync.database_writer.blocks_written` - Batch size distribution
- `bitblocks.sync.database_writer.total_blocks` - Total written (counter)

**What to Watch:**
- **High duration** - Database performance issue
- **High blocks_failed** - Data integrity or schema issues

### Database Metrics (Ecto)

Automatically emitted by Ecto for all queries:

- **Event:** `[:bitblocks, :repo, :query]`
- **Measurements:**
  - `total_time` - Total query time
  - `query_time` - Time spent executing on database
  - `queue_time` - Time waiting for connection from pool
  - `decode_time` - Time decoding results
  - `idle_time` - Time connection was idle

**Dashboard Metrics:**
- `bitblocks.repo.query.total_time` - Overall query performance
- `bitblocks.repo.query.queue_time` - Connection pool contention
- `bitblocks.repo.query.query_time` - Database execution time

**What to Watch:**
- **High queue_time** - Need to increase connection pool size
- **High query_time** - Slow queries, missing indexes
- **High decode_time** - Large result sets

### Phoenix/HTTP Metrics

Standard Phoenix telemetry events:

- `phoenix.endpoint.stop.duration` - Total request time
- `phoenix.router_dispatch.stop.duration` - Controller/LiveView time

### VM Metrics

Erlang VM health metrics:

- `vm.memory.total` - Total memory usage (megabytes)
- `vm.total_run_queue_lengths.total` - Scheduled processes
- `vm.total_run_queue_lengths.cpu` - CPU-bound processes
- `vm.total_run_queue_lengths.io` - I/O-bound processes

## Interpreting Metrics

### RPC Latency Analysis

**Typical Values (Remote Node):**
- Individual call: 50-200ms
- Batch call (100 requests): 100-500ms
- Batch efficiency: ~5-10x faster than individual calls

**If you see:**
- `call.duration > 500ms` - Network issues or node overload
- `batch.duration > 2000ms` - Large batch or slow node
- High error rate - Check node connectivity

**Query Example:**
```elixir
# In IEx, attach a handler to log slow RPC calls
:telemetry.attach(
  "slow-rpc-logger",
  [:bitblocks, :bitcoin_rpc, :call],
  fn _event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    if duration_ms > 500 do
      IO.puts("Slow RPC: #{metadata.method} took #{duration_ms}ms")
    end
  end,
  nil
)
```

### Sync Pipeline Analysis

**Healthy Pipeline:**
- BlockProducer: 100-500ms per batch of 50-100 blocks
- DatabaseWriter: 50-200ms per batch of 5-10 blocks
- Throughput: 100-500 blocks/minute

**Bottleneck Identification:**

1. **If BlockProducer is slow:**
   - Check RPC batch latency
   - Increase `transaction_fetcher_concurrency`
   - Verify network connection to Bitcoin node

2. **If DatabaseWriter is slow:**
   - Check database query times
   - Increase database connection pool
   - Consider batch inserts (not yet implemented)

3. **If both are slow but RPC is fast:**
   - Database might be the bottleneck
   - Check `repo.query.queue_time`

### Custom Telemetry Handlers

You can attach custom handlers to process telemetry events:

```elixir
# In config/runtime.exs or application.ex
defmodule MyApp.TelemetryLogger do
  require Logger

  def handle_event([:bitblocks, :bitcoin_rpc, :batch], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info(
      "Batch RPC completed",
      method: metadata.method,
      batch_size: measurements.batch_size,
      duration_ms: duration_ms,
      avg_per_request: duration_ms / measurements.batch_size
    )
  end
end

# Attach the handler
:telemetry.attach_many(
  "my-telemetry-logger",
  [
    [:bitblocks, :bitcoin_rpc, :batch],
    [:bitblocks, :sync, :block_producer],
    [:bitblocks, :sync, :database_writer]
  ],
  &MyApp.TelemetryLogger.handle_event/4,
  nil
)
```

## Exporting Metrics

### StatsD/DataDog

To export metrics to StatsD or DataDog:

```elixir
# mix.exs
{:telemetry_metrics_statsd, "~> 0.7"}

# lib/bitblocks/application.ex
children = [
  # ... existing children
  {TelemetryMetricsStatsd,
    host: "localhost",
    port: 8125,
    metrics: BitblocksWeb.Telemetry.metrics()
  }
]
```

### Prometheus

To export metrics to Prometheus:

```elixir
# mix.exs
{:telemetry_metrics_prometheus, "~> 1.1"}

# lib/bitblocks_web/router.ex
scope "/metrics" do
  get "/", TelemetryMetricsPrometheus, :metrics
end
```

### Custom Logger

Log metrics to structured logs for analysis:

```elixir
# lib/bitblocks/telemetry/logger.ex
defmodule Bitblocks.Telemetry.Logger do
  require Logger

  def handle_event(event, measurements, metadata, _config) do
    Logger.info(
      "Telemetry event",
      event: event,
      measurements: measurements,
      metadata: metadata
    )
  end
end
```

## Alerting Recommendations

### Critical Alerts

1. **RPC Error Rate > 10%**
   - May indicate Bitcoin node issues
   - Check node health and connectivity

2. **Database Queue Time > 1000ms**
   - Connection pool exhausted
   - Increase pool size or investigate slow queries

3. **Sync Pipeline Stopped**
   - Monitor `block_producer.total_blocks` counter
   - Alert if no increase for > 5 minutes

### Warning Alerts

1. **RPC Latency P95 > 1000ms**
   - Network degradation
   - Consider node location or bandwidth

2. **Database Write Failures > 1%**
   - Data quality issues
   - Schema migration needed

3. **VM Memory > 80%**
   - Memory leak or high load
   - Review memory usage patterns

## Performance Targets

Based on typical deployments:

| Metric | Target | Good | Needs Investigation |
|--------|--------|------|---------------------|
| RPC Call Latency | <200ms | <100ms | >500ms |
| Batch RPC Latency | <500ms | <300ms | >2000ms |
| Block Producer Duration | <500ms | <200ms | >2000ms |
| Database Write Duration | <100ms | <50ms | >500ms |
| Blocks/Minute | >100 | >500 | <50 |
| Database Queue Time | <50ms | <20ms | >200ms |

## Debugging with Telemetry

### Find Slow RPC Calls

```elixir
# Attach handler to track slow calls
:telemetry.attach(
  "rpc-tracker",
  [:bitblocks, :bitcoin_rpc, :call],
  fn _event, %{duration: duration}, %{method: method}, _config ->
    ms = System.convert_time_unit(duration, :native, :millisecond)
    if ms > 1000, do: IO.puts("SLOW: #{method} - #{ms}ms")
  end,
  nil
)
```

### Monitor Sync Progress

```elixir
# Track blocks synced per minute
Agent.start_link(fn -> {0, System.system_time(:second)} end, name: :sync_counter)

:telemetry.attach(
  "sync-rate",
  [:bitblocks, :sync, :database_writer],
  fn _event, %{blocks_written: count}, _meta, _config ->
    Agent.update(:sync_counter, fn {total, start_time} ->
      new_total = total + count
      now = System.system_time(:second)

      if now - start_time >= 60 do
        IO.puts("Sync rate: #{new_total} blocks/minute")
        {0, now}
      else
        {new_total, start_time}
      end
    end)
  end,
  nil
)
```

### Identify Bottlenecks

```elixir
# Compare stages
defmodule Bottleneck.Finder do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    :telemetry.attach_many(
      "bottleneck-finder",
      [
        [:bitblocks, :sync, :block_producer],
        [:bitblocks, :sync, :database_writer]
      ],
      &handle_event/4,
      nil
    )
    {:ok, %{producer: [], writer: []}}
  end

  def handle_event([:bitblocks, :sync, :block_producer], %{duration: d}, _, _) do
    GenServer.cast(__MODULE__, {:producer, d})
  end

  def handle_event([:bitblocks, :sync, :database_writer], %{duration: d}, _, _) do
    GenServer.cast(__MODULE__, {:writer, d})
  end

  def handle_cast({:producer, duration}, state) do
    new_producer = [duration | state.producer] |> Enum.take(100)
    check_bottleneck(%{state | producer: new_producer})
    {:noreply, %{state | producer: new_producer}}
  end

  def handle_cast({:writer, duration}, state) do
    new_writer = [duration | state.writer] |> Enum.take(100)
    check_bottleneck(%{state | writer: new_writer})
    {:noreply, %{state | writer: new_writer}}
  end

  defp check_bottleneck(%{producer: p, writer: w}) when length(p) > 10 and length(w) > 10 do
    avg_p = Enum.sum(p) / length(p) |> System.convert_time_unit(:native, :millisecond)
    avg_w = Enum.sum(w) / length(w) |> System.convert_time_unit(:native, :millisecond)

    if avg_p > avg_w * 2 do
      IO.puts("⚠️  BOTTLENECK: BlockProducer (#{round(avg_p)}ms vs Writer #{round(avg_w)}ms)")
    end

    if avg_w > avg_p * 2 do
      IO.puts("⚠️  BOTTLENECK: DatabaseWriter (#{round(avg_w)}ms vs Producer #{round(avg_p)}ms)")
    end
  end

  defp check_bottleneck(_), do: :ok
end
```

## Next Steps

1. **Set up dashboards** - Configure Grafana or DataDog
2. **Configure alerts** - Based on targets above
3. **Establish baselines** - Run for 24h to understand normal patterns
4. **Tune configuration** - Adjust concurrency based on metrics
5. **Monitor production** - Track metrics after deployment
