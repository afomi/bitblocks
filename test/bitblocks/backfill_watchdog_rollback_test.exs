defmodule Bitblocks.BackfillWatchdogRollbackTest do
  # The watchdog against a real transaction (https://github.com/afomi/bitblocks/issues/115):
  # a runner killed mid-statement leaves nothing committed, and its
  # statement is cancelled, so its locks are free at once. The runner works
  # on its own Postgrex connection, outside the sandbox, as a backfill's
  # pooled connection does in prod: inside the sandbox all of a test's work
  # rolls back anyway, so it couldn't show this.
  use Bitblocks.DataCase, async: false

  import ExUnit.CaptureLog

  alias Bitblocks.{BackfillChains, Derivations}

  # An advisory lock key no other test takes.
  @lock 115_119_001

  defp connect do
    {:ok, conn} =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])
      |> Postgrex.start_link()

    conn
  end

  setup do
    Application.put_env(:bitblocks, :backfill_watchdog_ms, 50)
    Application.put_env(:bitblocks, :backfill_watchdog_poll_ms, 10)

    on_exit(fn ->
      Application.delete_env(:bitblocks, :backfill_watchdog_ms)
      Application.delete_env(:bitblocks, :backfill_watchdog_poll_ms)
      Bitblocks.Shutdown.reset()
    end)

    # Outside the sandbox, as the other node sees the database.
    %{observer: connect(), marker: "watchdog-test-#{System.unique_integer([:positive])}"}
  end

  # What a batch does: a write, a row lock's stand-in, then a statement that
  # outlasts the window. The node starts to stop just before it.
  defp batch(marker) do
    conn = connect()

    Postgrex.transaction(
      conn,
      fn c ->
        Postgrex.query!(
          c,
          "INSERT INTO derivation_chains " <>
            "(derivation, range_from, range_to, range_step, next_from, inserted_at, updated_at) " <>
            "VALUES ($1, 0, 0, 1, 0, now(), now())",
          [marker]
        )

        Postgrex.query!(c, "SELECT pg_advisory_xact_lock($1)", [@lock])
        %{rows: [[pid, started]]} = Postgrex.query!(c, "SELECT pg_backend_pid(), now()", [])
        Derivations.put_open_transaction({pid, started})

        Bitblocks.Shutdown.begin()
        Postgrex.query!(c, "SELECT pg_sleep(30)", [], timeout: 60_000)
      end,
      timeout: 60_000
    )
  end

  defp committed?(observer, marker) do
    %{rows: [[n]]} =
      Postgrex.query!(
        observer,
        "SELECT count(*) FROM derivation_chains WHERE derivation = $1",
        [marker]
      )

    n > 0
  end

  defp lock_free?(observer) do
    %{rows: [[free]]} = Postgrex.query!(observer, "SELECT pg_try_advisory_lock($1)", [@lock])
    if free, do: Postgrex.query!(observer, "SELECT pg_advisory_unlock($1)", [@lock])
    free
  end

  test "a runner killed mid-statement commits nothing, and its lock is freed at once",
       %{observer: observer, marker: marker} do
    started = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        assert :watchdog = BackfillChains.run_watched(fn -> batch(marker) end)
      end)

    # The 30 s statement didn't hold the job: the watchdog's 50 ms did.
    assert System.monotonic_time(:millisecond) - started < 5_000

    # Postgrex's own disconnect cancels the statement and closes the session
    # (so the watchdog usually finds the transaction gone); either way the
    # log says which.
    assert log =~ "already ended" or log =~ "running statement was cancelled"

    # Nothing of the batch committed, and its lock is free within a second,
    # not at the statement's end 30 s on.
    refute committed?(observer, marker)
    assert Enum.any?(1..20, fn _ -> lock_free?(observer) || (Process.sleep(50) && false) end)
  end

  test "the guard: a backend still in the noted transaction and running is cancelled",
       %{observer: observer} do
    # The second line on its own: a statement on a live connection, cancelled
    # by the watchdog's query while that transaction is still open.
    test = self()
    conn = connect()

    Task.start(fn ->
      Postgrex.transaction(conn, fn c ->
        %{rows: [[pid, started]]} = Postgrex.query!(c, "SELECT pg_backend_pid(), now()", [])
        send(test, {:open, {pid, started}})

        result =
          try do
            Postgrex.query!(c, "SELECT pg_sleep(30)", [], timeout: 60_000)
          rescue
            e in Postgrex.Error -> e.postgres.code
          end

        send(test, {:statement, result})
      end)
    end)

    assert_receive {:open, open}, 5_000
    # Wait until it is running the sleep, as seen from outside.
    {pid, _} = open

    assert Enum.any?(1..100, fn _ ->
             %{rows: rows} =
               Postgrex.query!(observer, "SELECT state FROM pg_stat_activity WHERE pid = $1", [
                 pid
               ])

             rows == [["active"]] || (Process.sleep(10) && false)
           end)

    assert Derivations.cancel_transaction(open) == :cancelled
    assert_receive {:statement, :query_canceled}, 5_000
  end
end
