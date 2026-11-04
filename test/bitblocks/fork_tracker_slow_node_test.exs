defmodule Bitblocks.ForkTrackerSlowNodeTest do
  # 2026-11-04: a node catching up reports headers-only tips with branchlen
  # 104,881 and 15,839. ForkTracker walked each one header by header inside its
  # GenServer, so snapshot/0 timed out and /forks and /sync returned 500.
  use ExUnit.Case, async: false

  alias Bitblocks.ForkTracker

  defmodule SlowNode do
    @table :fork_tracker_slow_node_calls

    def setup do
      if :ets.whereis(@table) == :undefined,
        do: :ets.new(@table, [:named_table, :public, :set])

      :ets.insert(@table, {:headers, 0})
    end

    def header_calls, do: :ets.lookup_element(@table, :headers, 2)

    def getchaintips do
      [
        %{
          "hash" => "catchup_tip",
          "height" => 973_990,
          "branchlen" => 100_000,
          "status" => "headers-only",
          "chainwork" => "01"
        },
        %{
          "hash" => "old_fork",
          "height" => 500_000,
          "branchlen" => 5_000,
          "status" => "valid-fork",
          "chainwork" => "01"
        }
      ]
    end

    def getblockheader(hash, _verbose) do
      :ets.update_counter(@table, :headers, 1)
      Process.sleep(10)
      %{"hash" => hash, "previousblockhash" => hash <> "p", "height" => 1, "time" => 0}
    end
  end

  setup do
    SlowNode.setup()
    prev = Application.get_env(:bitblocks, :bitcoinsv_cli)
    Application.put_env(:bitblocks, :bitcoinsv_cli, SlowNode)
    ForkTracker.reset()
    ForkTracker.subscribe()

    on_exit(fn ->
      Application.put_env(:bitblocks, :bitcoinsv_cli, prev)
      ForkTracker.reset()
    end)

    :ok
  end

  test "snapshot answers at once while a poll walks a slow node" do
    ForkTracker.force_poll()
    Process.sleep(50)

    {micros, snapshot} = :timer.tc(&ForkTracker.snapshot/0)

    assert micros < 50_000
    assert is_list(snapshot.tips)

    assert_receive {:fork_update, _delta}, 5_000
  end

  test "a poll walks a bounded number of headers and skips headers-only tips" do
    ForkTracker.force_poll()
    assert_receive {:fork_update, delta}, 5_000

    # The 100k headers-only tip costs nothing; the fork walk is capped.
    assert SlowNode.header_calls() <= ForkTracker.max_branch_walk() + 1

    tips = Map.new(delta.tips, &{&1.hash, &1})
    assert tips["catchup_tip"].branch_len == 100_000
    assert tips["old_fork"].branch_len == 5_000
  end
end
