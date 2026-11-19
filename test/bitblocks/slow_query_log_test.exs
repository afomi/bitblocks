defmodule Bitblocks.SlowQueryLogTest do
  # A pool timeout names only its victim; this log names the slow statement
  # and its caller, without params.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bitblocks.TelemetryHandlers

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp emit(queue_ms, query_ms, options \\ []) do
    TelemetryHandlers.handle_slow_query(
      [:bitblocks, :repo, :query],
      %{queue_time: native(queue_ms), query_time: native(query_ms)},
      %{
        source: "transactions",
        query: "SELECT count(*) FROM transactions WHERE block_hash = $1",
        params: ["secret"],
        options: options
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

  test "a query marked expected_slow is skipped for its run time, but not for a long wait" do
    assert capture_log(fn -> emit(0, 45_000, expected_slow: true) end) == ""
    assert capture_log(fn -> emit(6_000, 45_000, expected_slow: true) end) =~ "queue=6000ms"
  end

  test "Repo passes telemetry_options through to the handler's metadata" do
    ref = make_ref()
    me = self()

    :telemetry.attach(
      "slow-query-options-#{inspect(ref)}",
      [:bitblocks, :repo, :query],
      fn _event, _measurements, metadata, _ -> send(me, {ref, metadata[:options]}) end,
      nil
    )

    try do
      Ecto.Adapters.SQL.Sandbox.checkout(Bitblocks.Repo)
      Bitblocks.Repo.query!("SELECT 1", [], telemetry_options: [expected_slow: true])
      assert_receive {^ref, options}
      assert options[:expected_slow] == true
    after
      :telemetry.detach("slow-query-options-#{inspect(ref)}")
    end
  end
end
