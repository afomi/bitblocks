defmodule Bitblocks.TelemetryHandlers do
  @moduledoc false

  require Logger

  @handler_id "bitblocks-slow-rpc-logger"

  @slow_rpc_events [
    [:bitblocks, :bitcoin_rpc, :call],
    [:bitblocks, :bitcoin_rpc, :batch]
  ]

  @doc """
  Attaches telemetry handlers used for operational visibility.
  Safe to call multiple times; subsequent calls are no-ops.
  """
  def attach do
    case :telemetry.attach_many(@handler_id, @slow_rpc_events, &__MODULE__.handle_slow_rpc/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  def handle_slow_rpc(event, measurements, metadata, _config) do
    duration_native = measurements[:duration] || 0
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)
    threshold_ms = Application.get_env(:bitblocks, :slow_rpc_log_threshold_ms, 30_000)

    if duration_ms >= threshold_ms do
      method = metadata[:method] || "unknown"
      result = metadata[:result] || :unknown

      Logger.warning(
        "Slow Bitcoin RPC call detected (#{format_event(event)}): method=#{method} " <>
          "duration=#{duration_ms}ms result=#{result}"
      )
    end
  end

  defp format_event(event) do
    event
    |> Enum.map(&to_string/1)
    |> Enum.join(".")
  end
end
