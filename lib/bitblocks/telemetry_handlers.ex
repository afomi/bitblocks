defmodule Bitblocks.TelemetryHandlers do
  @moduledoc false

  require Logger

  @handler_id "bitblocks-slow-rpc-logger"
  @query_handler_id "bitblocks-slow-query-logger"
  @query_event [:bitblocks, :repo, :query]

  @slow_rpc_events [
    [:bitblocks, :bitcoin_rpc, :call],
    [:bitblocks, :bitcoin_rpc, :batch]
  ]

  @doc """
  Attaches telemetry handlers used for operational visibility.
  Safe to call multiple times; subsequent calls are no-ops.
  """
  def attach do
    for {id, events, fun} <- [
          {@handler_id, @slow_rpc_events, &__MODULE__.handle_slow_rpc/4},
          {@query_handler_id, [@query_event], &__MODULE__.handle_slow_query/4}
        ] do
      case :telemetry.attach_many(id, events, fun, %{}) do
        :ok -> :ok
        {:error, :already_exists} -> :ok
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Logs a Repo query that waited long for a connection or ran long, so a pool
  timeout ("checked out the connection for longer than 60000ms") names its
  statement and its caller instead of only the victim. Thresholds:
  `:slow_query_queue_ms` (default 5,000) and `:slow_query_run_ms` (10,000).
  Params are never logged.
  """
  def handle_slow_query(_event, measurements, metadata, _config) do
    queue_ms = ms(measurements[:queue_time])
    query_ms = ms(measurements[:query_time])

    if queue_ms >= Application.get_env(:bitblocks, :slow_query_queue_ms, 5_000) or
         query_ms >= Application.get_env(:bitblocks, :slow_query_run_ms, 10_000) do
      Logger.warning(
        "Slow DB query: queue=#{queue_ms}ms query=#{query_ms}ms source=#{metadata[:source] || "-"} " <>
          "caller=#{caller()} sql=#{metadata[:query] |> to_string() |> String.slice(0, 200)}"
      )
    end
  end

  defp ms(nil), do: 0
  defp ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  # The process running the query, by its label (Oban labels a job's process
  # with its worker; DBConnection's timeout error prints the same label), else
  # its initial call.
  defp caller do
    case Process.get(:"$process_label") do
      nil ->
        case Process.get(:"$initial_call") do
          {m, f, a} -> "#{inspect(m)}.#{f}/#{a}"
          _ -> inspect(self())
        end

      label ->
        inspect(label)
    end
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
