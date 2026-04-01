defmodule Bitblocks.ForkTrackerTest do
  use ExUnit.Case, async: false
  use ExVCR.Mock, adapter: ExVCR.Adapter.Hackney

  import Bitblocks.DataCase, only: [setup_bitcoin_rpc: 0]

  alias Bitblocks.ForkTracker

  @state_path "tmp/fork_tracker/state.etf"
  @log_path "tmp/fork_tracker/fork_tape.log"

  setup do
    setup_bitcoin_rpc()

    ForkTracker.reset()

    on_exit(fn ->
      File.rm(@state_path)
      File.rm(@log_path)
    end)

    :ok
  end

  test "ingests chain tips and exposes snapshot" do
    use_cassette "fork_tracker/ingest_tips_with_fork", record: :none do
      tips = [
        %{
          "hash" => "main_120",
          "height" => 120,
          "branchlen" => 0,
          "status" => "active",
          "chainwork" => "0000000000000000000000000000000000000000000000000000000000100100"
        },
        %{
          "hash" => "fork_120",
          "height" => 120,
          "branchlen" => 2,
          "status" => "valid-fork",
          "chainwork" => "00000000000000000000000000000000000000000000000000000000000f0010"
        }
      ]

      ForkTracker.ingest_chaintips(tips, source: "mock")
      # Give the cast time to process.
      Process.sleep(100)

      snapshot = ForkTracker.snapshot()

      assert snapshot.version > 0
      assert Enum.any?(snapshot.tips, fn tip -> tip.hash == "fork_120" and tip.branch_len == 2 end)

      fork_nodes =
        snapshot.nodes
        |> Enum.filter(&(&1.branch_root == "common_118"))
        |> Enum.map(& &1.hash)

      assert "fork_119" in fork_nodes
      assert "fork_120" in fork_nodes

      assert snapshot.base_height >= 117
      assert snapshot.base_height <= 118
    end
  end

  test "appends contention entries to fork tape" do
    use_cassette "fork_tracker/fork_tape_entry", record: :none do
      ForkTracker.ingest_chaintips([
        %{"hash" => "fork_120", "height" => 120, "branchlen" => 2, "status" => "valid-fork"}
      ])

      Process.sleep(100)
      _ = ForkTracker.snapshot()

      events = ForkTracker.recent_events(5)
      assert Enum.any?(events, fn line -> String.contains?(line, "fork_120") end)
    end
  end
end
