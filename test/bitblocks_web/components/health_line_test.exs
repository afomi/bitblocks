defmodule BitblocksWeb.HealthLineTest do
  # #44: /sync and /status lead with one plain answer, from Ops.health/1:
  # how far the index is complete, how fresh it is, the node's state and lag,
  # failed blocks, and whether the sync is moving.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Bitblocks.Ops
  alias BitblocksWeb.ChainStatusComponent
  alias BitblocksWeb.HealthLine

  @now ~U[2026-11-04 12:00:00Z]

  defp health(overrides) do
    %{
      node: %{"chain" => "main", "blocks" => 943_900, "headers" => 958_900},
      overview: %{
        our_tip: 943_900,
        complete_through: 162_000,
        public_tip: 958_905,
        states: [{"completed", 162_001}, {"failed", 2}]
      },
      latest_block_at: DateTime.add(@now, -7200, :second),
      last_completed_at: DateTime.add(@now, -180, :second),
      blocks_in_progress: 1,
      release: %{sha: nil, node: "node-1"},
      now: @now
    }
    |> Map.merge(overrides)
    |> Ops.health()
  end

  defp line(h), do: render_component(&HealthLine.health_line/1, health: h)

  test "a node catching up: complete through, freshness, node lag, failures, moving" do
    html = line(health(%{}))

    assert html =~ "Complete through block 162,000 of 943,900 known, 781,900 behind our node."
    assert html =~ "The last block completed 3 min ago."
    assert html =~ "Our node is up at block 943,900, 15,005 behind the network."
    assert html =~ "2 blocks failed and are retrying."
    assert html =~ "The sync is progressing."
  end

  test "a down node says so" do
    html = line(health(%{node: {:error, :econnrefused}}))
    assert html =~ "Node unreachable."
  end

  test "a warming node says why" do
    html =
      line(health(%{node: {:error, %{"code" => -28, "message" => "Loading block index..."}}}))

    assert html =~ "Our node is warming up: Loading block index..."
  end

  test "a stall says which part stopped" do
    html =
      line(
        health(%{
          last_completed_at: DateTime.add(@now, -7200, :second),
          blocks_in_progress: 0
        })
      )

    assert html =~ "The sync has stalled: no block has completed for over an hour."
  end

  test "health counts failed blocks from the snapshot's states" do
    assert health(%{}).index.failed == 2
  end

  describe "the node card" do
    defp card(h, info) do
      render_component(&ChainStatusComponent.chain_status/1,
        blockchain_info: info,
        node: h.node,
        complete_through: h.index.complete_through
      )
    end

    @info %{chain: "main", blocks: 943_900, headers: 943_900, verificationprogress: 1.0}

    test "\"Fully Synced\" only when our index is complete through the node's tip" do
      refute card(health(%{}), @info) =~ "Fully Synced"

      synced =
        health(%{
          overview: %{our_tip: 943_900, complete_through: 943_900, public_tip: 943_900}
        })

      assert card(synced, @info) =~ "Fully Synced"
    end

    test "a down node reads \"Node unreachable\", not an empty card" do
      html = card(health(%{node: {:error, :econnrefused}}), nil)
      assert html =~ "Node unreachable"
    end
  end
end
