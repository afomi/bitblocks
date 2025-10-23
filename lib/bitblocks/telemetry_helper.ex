defmodule Bitblocks.TelemetryHelper do
  @moduledoc """
  Helper utilities for telemetry measurement and event execution.

  Provides consistent patterns for measuring operation duration and emitting
  telemetry events across the application.
  """

  @doc """
  Measures the duration of a function execution and emits a telemetry event.

  Automatically captures the duration in native time units and includes it in
  the measurements map.

  ## Parameters

  - `event_name` - The telemetry event name (list of atoms)
  - `metadata` - Map of metadata to include with the event (default: %{})
  - `measurements` - Map of measurements to include (default: %{}), duration will be added
  - `fun` - Zero-arity function to execute and measure

  ## Examples

      iex> result = measure([:my_app, :operation], %{user_id: 123}, fn ->
      ...>   # expensive operation
      ...>   :ok
      ...> end)
      :ok

      # Emits telemetry with %{duration: 1234567} in native time units

  """
  def measure(event_name, metadata \\ %{}, measurements \\ %{}, fun) when is_function(fun, 0) do
    start_time = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      event_name,
      Map.put(measurements, :duration, duration),
      metadata
    )

    result
  end

  @doc """
  Measures operation duration and automatically includes result status in metadata.

  Inspects the result and adds a `:result` key to metadata with either `:ok` or `:error`
  based on whether the result matches `{:error, _}`.

  ## Examples

      iex> measure_with_result([:my_app, :fetch], %{id: 123}, fn ->
      ...>   {:ok, "data"}
      ...> end)
      {:ok, "data"}

      # Emits telemetry with metadata: %{id: 123, result: :ok}

      iex> measure_with_result([:my_app, :fetch], %{id: 456}, fn ->
      ...>   {:error, :not_found}
      ...> end)
      {:error, :not_found}

      # Emits telemetry with metadata: %{id: 456, result: :error}

  """
  def measure_with_result(event_name, metadata \\ %{}, measurements \\ %{}, fun)
      when is_function(fun, 0) do
    start_time = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start_time

    result_status = if match?({:error, _}, result), do: :error, else: :ok

    :telemetry.execute(
      event_name,
      Map.put(measurements, :duration, duration),
      Map.put(metadata, :result, result_status)
    )

    result
  end

  @doc """
  Wraps a function with telemetry measurement for RPC calls.

  Convenience wrapper specifically for Bitcoin RPC calls that includes the method
  name in metadata and automatically tracks success/failure.

  ## Examples

      iex> measure_rpc("getblock", fn ->
      ...>   BitcoinsvCli.getblock("hash123")
      ...> end)
      %{"height" => 100, ...}

      # Emits [:bitblocks, :bitcoin_rpc, :call] with metadata: %{method: "getblock", result: :ok}

  """
  def measure_rpc(method, fun) when is_function(fun, 0) do
    measure_with_result(
      [:bitblocks, :bitcoin_rpc, :call],
      %{method: method},
      %{},
      fun
    )
  end

  @doc """
  Wraps a function with telemetry measurement for batch RPC calls.

  Similar to measure_rpc but for batch operations, includes batch_size in measurements.

  ## Examples

      iex> measure_batch_rpc("getblockhash", 100, fn ->
      ...>   BitcoinsvCli.batch_getblockhash([0, 1, 2, ...])
      ...> end)
      {:ok, %{0 => "hash0", 1 => "hash1", ...}}

      # Emits [:bitblocks, :bitcoin_rpc, :batch] with:
      # - measurements: %{batch_size: 100}
      # - metadata: %{method: "getblockhash", result: :ok}

  """
  def measure_batch_rpc(method, batch_size, fun) when is_function(fun, 0) do
    measure_with_result(
      [:bitblocks, :bitcoin_rpc, :batch],
      %{method: method},
      %{batch_size: batch_size},
      fun
    )
  end

  @doc """
  Convenience function to emit a simple telemetry event without measurements.

  Useful for counter-style events that don't need duration tracking.

  ## Examples

      iex> emit([:bitblocks, :sync, :block_skipped], %{height: 100})
      :ok

  """
  def emit(event_name, metadata \\ %{}) do
    :telemetry.execute(event_name, %{}, metadata)
  end

  @doc """
  Emits a telemetry event with a single count measurement.

  Useful for tracking occurrences of events.

  ## Examples

      iex> emit_count([:bitblocks, :errors, :rpc_timeout], 1, %{method: "getblock"})
      :ok

  """
  def emit_count(event_name, count, metadata \\ %{}) do
    :telemetry.execute(event_name, %{count: count}, metadata)
  end
end
