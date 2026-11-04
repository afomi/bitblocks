defmodule Bitblocks.OpsTest do
  # One place that answers "is it healthy, how current is it" as data, for
  # /api/v1/status, alerts and (later) the operator MCP. The node was down
  # from July to November 2026 and nothing said so (docs/OPS_API_AND_MCP.md).
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias Bitblocks.Ops

  @now ~U[2026-11-04 12:00:00Z]

  defp facts(overrides) do
    Map.merge(
      %{
        node: %{"chain" => "main", "blocks" => 958_900, "headers" => 958_900},
        overview: %{
          our_tip: 958_900,
          complete_through: 162_000,
          node_tip: 958_900,
          node_headers: 958_900,
          public_tip: 958_905
        },
        latest_block_at: DateTime.add(@now, -300, :second),
        now: @now
      },
      overrides
    )
  end

  test "healthy: our tip follows the node, the node follows the network" do
    h = Ops.health(facts(%{}))

    assert h.status == "ok"
    assert h.index.tip == 958_900
    assert h.index.complete_through == 162_000
    assert h.node.state == "ok"
    assert h.lag.index_behind_node == 0
    assert h.lag.node_behind_network == 5
  end

  test "a warming node is degraded, not down" do
    h = Ops.health(facts(%{node: {:error, %{"code" => -28, "message" => "Verifying blocks..."}}}))
    assert h.status == "degraded"
    assert h.node.state == "warming_up"
    assert h.node.message == "Verifying blocks..."
  end

  test "an unreachable node is down" do
    h = Ops.health(facts(%{node: {:error, :econnrefused}}))
    assert h.status == "down"
    assert h.node.state == "unreachable"
  end

  test "our index stuck behind the node is degraded" do
    h =
      Ops.health(
        facts(%{
          overview: %{
            our_tip: 957_301,
            complete_through: 1,
            node_tip: 958_900,
            node_headers: 958_900
          },
          latest_block_at: DateTime.add(@now, -7200, :second)
        })
      )

    assert h.status == "degraded"
    assert h.lag.index_behind_node == 1_599
    assert "index_stalled" in h.problems
  end

  test "health never carries the node's address" do
    h = Ops.health(facts(%{}))
    refute inspect(h) =~ "8332"
    refute inspect(h) =~ "http"
  end

  describe "alerts" do
    setup do
      Ops.reset_alerts()
      :ok
    end

    test "a down node sends one email, not one per check" do
      down = facts(%{node: {:error, :econnrefused}})

      Ops.alert(Ops.health(down))
      assert_email_sent(subject: "Bitblocks: node unreachable")

      Ops.alert(Ops.health(down))
      refute_email_sent()
    end

    test "a stalled index sends its own email" do
      stalled =
        facts(%{
          overview: %{
            our_tip: 957_301,
            complete_through: 1,
            node_tip: 958_900,
            node_headers: 958_900
          },
          latest_block_at: DateTime.add(@now, -7200, :second)
        })

      Ops.alert(Ops.health(stalled))
      assert_email_sent(subject: "Bitblocks: index stalled behind the node")
    end

    test "a healthy check sends nothing" do
      Ops.alert(Ops.health(facts(%{})))
      refute_email_sent()
    end
  end

  test "health names the running release, so a deploy can be confirmed" do
    h = Ops.health(facts(%{release: %{sha: "abc1234", node: "bitblocks@10.0.0.1"}}))
    assert h.release.sha == "abc1234"
  end

  describe "coverage" do
    test "turns per-bucket counts, the completion rate and the tip into a curve and an ETA" do
      c =
        Ops.coverage(%{
          buckets: [
            %{bucket: 0, present: 10_000, completed: 10_000},
            %{bucket: 1, present: 10_000, completed: 4_000}
          ],
          complete_through: 13_999,
          tip: 19_999,
          completed_last_hour: 600
        })

      assert [%{from: 0, to: 9_999, complete_pct: 100.0}, %{from: 10_000, complete_pct: 40.0}] =
               c.buckets

      assert c.remaining == 6_000
      assert c.blocks_per_hour == 600
      assert c.eta_hours == 10.0
    end

    test "with nothing completing, no ETA" do
      c =
        Ops.coverage(%{buckets: [], complete_through: 5, tip: 10, completed_last_hour: 0})

      assert c.eta_hours == nil
    end
  end
end
