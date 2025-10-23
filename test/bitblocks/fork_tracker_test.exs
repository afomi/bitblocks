defmodule Bitblocks.ForkTrackerTest do
  use ExUnit.Case, async: false

  alias Bitblocks.ForkTracker
  alias BitblocksWeb.RpcStub

  @state_path "tmp/fork_tracker/state.etf"
  @log_path "tmp/fork_tracker/fork_tape.log"

  setup do
    RpcStub.setup()
    Application.put_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCliMock)
    ForkTracker.reset()

    on_exit(fn ->
      Application.delete_env(:bitblocks, :bitcoinsv_cli)
      File.rm(@state_path)
      File.rm(@log_path)
      ForkTracker.reset()
      RpcStub.clear()
    end)

    :ok
  end

  test "ingests chain tips and exposes snapshot" do
    seed_headers()

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

    RpcStub.stub_getchaintips(tips)

    ForkTracker.ingest_chaintips(tips, source: "mock")

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

  test "appends contention entries to fork tape" do
    seed_headers()

    RpcStub.stub_getchaintips([
      %{
        "hash" => "fork_120",
        "height" => 120,
        "branchlen" => 2,
        "status" => "valid-fork"
      }
    ])

    ForkTracker.ingest_chaintips([
      %{"hash" => "fork_120", "height" => 120, "branchlen" => 2, "status" => "valid-fork"}
    ])

    _ = ForkTracker.snapshot()

    events = ForkTracker.recent_events(5)

    assert Enum.any?(events, fn line -> String.contains?(line, "fork_120") end)
  end

  defp seed_headers do
    RpcStub.stub_getblockheader("main_120", true, header("main_120", 120, "main_119"))
    RpcStub.stub_getblockheader("main_119", true, header("main_119", 119, "common_118"))
    RpcStub.stub_getblockheader("fork_120", true, header("fork_120", 120, "fork_119"))
    RpcStub.stub_getblockheader("fork_119", true, header("fork_119", 119, "common_118"))
    RpcStub.stub_getblockheader("common_118", true, header("common_118", 118, "common_117"))
    RpcStub.stub_getblockheader("common_117", true, header("common_117", 117, nil))
  end

  defp header(hash, height, parent) do
    %{
      "hash" => hash,
      "height" => height,
      "time" => 1_693_929_600 + height,
      "chainwork" => Integer.to_string(65_000 + height, 16),
      "previousblockhash" => parent
    }
  end
end
