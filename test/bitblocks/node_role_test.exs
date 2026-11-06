defmodule Bitblocks.NodeRoleTest do
  # #39: more web instances add read capacity, never another writer.
  use ExUnit.Case, async: true

  alias Bitblocks.NodeRole

  @oban [
    repo: Bitblocks.Repo,
    queues: [default: 10, sync_blocks: 1, blocks: 1],
    plugins: [Oban.Plugins.Pruner]
  ]

  test "this node is a writer unless configured otherwise" do
    assert NodeRole.role() == :writer
  end

  test "a writer's Oban config is untouched" do
    assert NodeRole.oban_config(@oban, :writer) == @oban
  end

  test "a reader's Oban runs no queue, no plugin and takes no part in leadership" do
    config = NodeRole.oban_config(@oban, :reader)

    assert config[:queues] == []
    assert config[:plugins] == []
    assert config[:peer] == false
    assert config[:repo] == Bitblocks.Repo

    # Oban accepts it, so a reader boots.
    assert %Oban.Config{queues: [], plugins: [], peer: {_module, _opts}} = Oban.Config.new(config)
  end

  test "a reader starts no coordinator" do
    assert NodeRole.writer_only(Bitblocks.Sync.Coordinator, :writer) == [
             Bitblocks.Sync.Coordinator
           ]

    assert NodeRole.writer_only(Bitblocks.Sync.Coordinator, :reader) == []
  end

  describe "status/3" do
    test "a leader alone: the sync writer, with limits per node" do
      assert %{
               role: "writer",
               sync_writer: true,
               connected_nodes: 0,
               rate_limit_scope: "per_node"
             } = NodeRole.status(:writer, [], fn -> true end)
    end

    test "a writer that doesn't lead isn't the sync writer" do
      assert %{sync_writer: false} = NodeRole.status(:writer, [], fn -> false end)
    end

    test "a reader never is, and never asks" do
      assert %{role: "reader", sync_writer: false} =
               NodeRole.status(:reader, [], fn -> flunk("a reader has no peer to ask") end)
    end

    test "limits are shared once a peer is connected" do
      assert %{connected_nodes: 1, rate_limit_scope: "cluster"} =
               NodeRole.status(:writer, [:bitblocks@peer], fn -> true end)
    end
  end
end
