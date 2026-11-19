defmodule Bitblocks.DerivationsPaceTest do
  # A batch's wall time (https://github.com/afomi/bitblocks/issues/115): the
  # deadline ends a batch between blocks or pages, and the sizes adapt from
  # the last batch. Driven by a fake clock that only the work moves, so no
  # test waits on real time.
  use Bitblocks.DataCase, async: false

  alias Bitblocks.Derivations

  describe "resize/5: shrink fast, grow slowly" do
    test "over the target it at least halves, to what fits in half the target" do
      # 100 blocks took 40 s against 20 s: half the target fits 25.
      assert Derivations.resize(100, 40_000, 100, 20_000, 100) == 25
      # Just over: at least halves (what fits in half the target is 47).
      assert Derivations.resize(100, 21_000, 100, 20_000, 100) == 47
      assert Derivations.resize(100, 20_001, 10, 20_000, 100) == 4
      # One block that alone took a minute: down to one, never zero.
      assert Derivations.resize(8, 60_000, 1, 20_000, 100) == 1
    end

    test "at or under half the target it grows by a quarter, at least one" do
      assert Derivations.resize(40, 5_000, 40, 20_000, 100) == 50
      assert Derivations.resize(1, 100, 1, 20_000, 100) == 2
      # Never above the configured most.
      assert Derivations.resize(90, 100, 90, 20_000, 100) == 100
    end

    test "between half and the whole target it holds" do
      assert Derivations.resize(30, 15_000, 30, 20_000, 100) == 30
    end
  end

  test "outside a run, time is never up and the limits are the configured ones" do
    refute Derivations.time_up?()
    assert Derivations.batch_limit(100) == 100
    assert Derivations.page_limit(200) == 200
  end

  # A clock that moves only when a block costs time.
  defp fake_clock do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {fn -> Agent.get(clock, & &1) end, fn ms -> Agent.update(clock, &(&1 + ms)) end}
  end

  # A backfill over `costs` (ms per block, by height), read by batch_limit
  # and walked by walk_blocks, as the block backfills do. Records each
  # batch's limit, blocks and time.
  defp synthetic(costs, opts) do
    {now, advance} = fake_clock()
    {:ok, log} = Agent.start_link(fn -> [] end)
    blocks = for {cost, h} <- Enum.with_index(costs), do: %{id: h + 1, height: h, cost: cost}

    next = fn cursor, report ->
      limit = Derivations.batch_limit(100)
      started = now.()

      case blocks |> Enum.filter(&after?(&1, cursor)) |> Enum.take(limit) do
        [] ->
          :done

        batch ->
          result =
            Derivations.walk_blocks(batch, cursor, report, fn b, _after_tx, report ->
              advance.(b.cost)
              {:done, %{report | blocks_examined: report.blocks_examined + 1}}
            end)

          {:cont, _, done} = result
          walked = done.blocks_examined - report.blocks_examined
          Agent.update(log, &[%{limit: limit, blocks: walked, ms: now.() - started} | &1])
          result
      end
    end

    report =
      Derivations.run(
        %{
          derivation: "synthetic",
          version: 1,
          from_height: 0,
          to_height: length(costs) - 1,
          cursor: {-1, 0},
          details: %{},
          next: next
        },
        Keyword.merge([record: false, clock: now], opts)
      )

    {report, log |> Agent.get(& &1) |> Enum.reverse()}
  end

  defp after?(b, {h, id}), do: b.height > h or (b.height == h and b.id > id)

  test "dense blocks: every batch ends within the cap plus one block, and the size falls" do
    # 300 blocks of 3 s each against a 20 s cap.
    {report, batches} = synthetic(List.duplicate(3_000, 300), batch_ms: 20_000)

    assert report.outcome == "ok"
    assert report.blocks_examined == 300
    assert Enum.all?(batches, &(&1.ms <= 20_000 + 3_000))
    # The first batch read 100 blocks and walked 7; the next read no more
    # than about what fits.
    assert [%{limit: 100, blocks: 7} | rest] = batches
    assert Enum.all?(rest, &(&1.limit <= 7))
  end

  test "blocks that turn cheap grow the size again, by a quarter a batch" do
    costs = List.duplicate(15_000, 6) ++ List.duplicate(10, 400)
    {report, batches} = synthetic(costs, batch_ms: 20_000)

    assert report.blocks_examined == 406
    assert Enum.all?(batches, &(&1.ms <= 20_000 + 15_000))

    limits = Enum.map(batches, & &1.limit)
    assert Enum.min(limits) == 1

    # From the smallest on, never more than a quarter (or one) up per batch.
    limits
    |> Enum.drop_while(&(&1 != 1))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] -> assert b <= a + max(1, div(a, 4)) end)

    assert List.last(limits) > 1
  end

  test "interrupt? ends the batch at the next block" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    interrupt = fn -> Agent.get_and_update(calls, &{&1 >= 3, &1 + 1}) end

    {report, batches} =
      synthetic(List.duplicate(1, 20), batch_ms: 20_000, interrupt?: interrupt)

    assert report.blocks_examined == 20
    assert hd(batches).blocks < 20
  end

  describe "the watchdog's statement cancel" do
    test "outside a bounded transaction a process has none open" do
      assert Derivations.open_transaction(self()) == nil
    end

    test "a watched bounded transaction notes its backend and start" do
      Derivations.bounded([watched: true], fn ->
        assert {pid, %DateTime{}} = Derivations.open_transaction(self())
        assert is_integer(pid)
      end)

      assert Derivations.open_transaction(self()) == nil
    end

    test "cancels nothing on a backend no longer in that transaction" do
      %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
      assert Derivations.cancel_transaction({pid, ~U[2000-01-01 00:00:00.000000Z]}) == :gone
      assert Derivations.cancel_transaction(nil) == :none
    end
  end
end
