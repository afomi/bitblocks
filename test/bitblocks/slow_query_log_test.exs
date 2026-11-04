defmodule Bitblocks.SlowQueryLogTest do
  # A pool timeout names only its victim; this log names the slow statement
  # and its caller, without params.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bitblocks.TelemetryHandlers

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp emit(queue_ms, query_ms) do
    TelemetryHandlers.handle_slow_query(
      [:bitblocks, :repo, :query],
      %{queue_time: native(queue_ms), query_time: native(query_ms)},
      %{
        source: "transactions",
        query: "SELECT count(*) FROM transactions WHERE block_hash = $1",
        params: ["secret"]
      },
      %{}
    )
  end

  test "a query that waited for a connection is logged with its source, caller and SQL, never its params" do
    Process.set_label(Bitblocks.Workers.FetchTransactionsWorker)

    log = capture_log(fn -> emit(6_000, 20) end)
    assert log =~ "Slow DB query: queue=6000ms query=20ms source=transactions"
    assert log =~ "caller=Bitblocks.Workers.FetchTransactionsWorker"
    assert log =~ "SELECT count(*) FROM transactions"
    refute log =~ "secret"
  end

  test "a long-running query is logged; a quick one is not" do
    assert capture_log(fn -> emit(0, 12_000) end) =~ "query=12000ms"
    assert capture_log(fn -> emit(100, 200) end) == ""
  end
end
