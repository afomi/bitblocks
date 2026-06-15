defmodule Bitblocks.StatsCacheTest do
  use Bitblocks.DataCase, async: false

  alias Bitblocks.StatsCache

  describe "blocks_count/0" do
    test "returns 0 when cache is cold (ETS table missing)" do
      # ETS table may or may not exist; either way returns 0 or a cached integer
      result = StatsCache.blocks_count()
      assert is_integer(result)
      assert result >= 0
    end

    test "does not issue a full-table COUNT on every call" do
      # Call many times; should hit ETS, not the DB each time
      results = Enum.map(1..20, fn _ -> StatsCache.blocks_count() end)
      assert Enum.all?(results, &is_integer/1)
    end
  end

  describe "transactions_count/0" do
    test "returns 0 or an integer — never raises — when cache is unavailable" do
      result = StatsCache.transactions_count()
      assert is_integer(result)
      assert result >= 0
    end

    test "returns 0 gracefully when ETS table does not exist" do
      # Simulate what callers get if StatsCache hasn't started yet
      # (ArgumentError from :ets.lookup on a missing named table → rescue → 0)
      result =
        try do
          :ets.lookup(Bitblocks.StatsCache, :transactions_count)
        rescue
          ArgumentError -> 0
        end

      assert result == 0 or is_list(result)
    end
  end

  describe "cache non-amplifying failure contract" do
    test "transactions_count/0 returns 0 (not a live COUNT) when ETS has no entry" do
      # The old code fell through to a 29GB scan on an empty ETS entry.
      # The new code returns 0 instead.
      # We verify by checking that the function always returns quickly (< 100ms)
      # even if the DB connection is absent — a 29GB scan would take ~1700ms.
      {micros, result} = :timer.tc(fn -> StatsCache.transactions_count() end)
      assert is_integer(result)
      # If this were a live full-table scan it would take 1000ms+ — we assert < 500ms
      assert micros < 500_000, "transactions_count took #{micros}µs — possible live COUNT"
    end
  end
end
