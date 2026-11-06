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
        last_completed_at: DateTime.add(@now, -60, :second),
        blocks_in_progress: 0,
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
    assert h.index.stalled == "headers"
  end

  describe "a node catching up (prod, 2026-11-04)" do
    # The node's validated blocks trail its headers by 15k; our headers follow
    # its blocks, so no new header lands for hours while the loop completes
    # blocks below. That is progress, not a stall.
    defp catching_up(overrides) do
      facts(
        Map.merge(
          %{
            node: %{"chain" => "main", "blocks" => 943_900, "headers" => 958_900},
            overview: %{
              our_tip: 943_900,
              complete_through: 162_000,
              node_tip: 943_900,
              node_headers: 958_900,
              public_tip: 958_905
            },
            latest_block_at: DateTime.add(@now, -7200, :second)
          },
          overrides
        )
      )
    end

    test "completing blocks with no new header is not a stall" do
      h = Ops.health(catching_up(%{}))

      refute "index_stalled" in h.problems
      assert h.status == "ok"
      assert h.lag.index_behind_node == 0
    end

    test "the node's lag is its validated blocks against the network, not its headers" do
      h = Ops.health(catching_up(%{}))

      assert h.node.blocks == 943_900
      assert h.node.headers == 958_900
      assert h.lag.node_behind_network == 15_005
      assert h.lag.node_headers_behind_network == 5
    end

    test "no block completed for an hour, with blocks left to complete, is a stall" do
      h = Ops.health(catching_up(%{last_completed_at: DateTime.add(@now, -7200, :second)}))

      assert "index_stalled" in h.problems
      assert h.index.stalled == "blocks"
      assert h.index.last_completed_at == "2026-11-04T10:00:00Z"
    end

    test "a long block still being worked, with no failures, is not a stall" do
      h =
        Ops.health(
          catching_up(%{
            last_completed_at: DateTime.add(@now, -7200, :second),
            blocks_in_progress: 1
          })
        )

      refute "index_stalled" in h.problems
    end

    test "nothing to complete is not a stall, however long since the last block" do
      h =
        Ops.health(
          catching_up(%{
            overview: %{
              our_tip: 943_900,
              complete_through: 943_900,
              node_tip: 943_900,
              node_headers: 958_900,
              public_tip: 958_905
            },
            last_completed_at: DateTime.add(@now, -86_400, :second)
          })
        )

      refute "index_stalled" in h.problems
    end

    test "a paused sync is not a stall: it says paused, and emails nothing" do
      Ops.reset_alerts()

      h =
        Ops.health(
          catching_up(%{last_completed_at: DateTime.add(@now, -7200, :second), paused: true})
        )

      assert h.problems == ["sync_paused"]
      assert h.status == "degraded"
      assert h.index.paused == true
      assert h.index.stalled == nil
      assert Ops.alert(h) == []
    end

    test "a node loading its block index says so, with no lag it can't know" do
      h =
        Ops.health(
          catching_up(%{
            node: {:error, %{"code" => -28, "message" => "Loading block index..."}},
            overview: %{our_tip: 943_900, complete_through: 162_000, public_tip: 958_905}
          })
        )

      assert h.problems == ["node_warming_up"]
      assert h.status == "degraded"
      assert h.node.state == "warming_up"
      assert h.node.message == "Loading block index..."
      assert h.node.blocks == nil
      assert h.lag.node_behind_network == nil
      assert h.lag.index_behind_node == nil
    end
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

      assert_email_sent(fn email ->
        assert email.subject == "Bitblocks: index stalled"
        assert email.text_body =~ "Our headers are 1599 blocks behind the node"
      end)
    end

    test "a stall in completing blocks says which block it is stuck above" do
      stalled =
        facts(%{
          overview: %{our_tip: 958_900, complete_through: 162_000, public_tip: 958_905},
          last_completed_at: DateTime.add(@now, -7200, :second)
        })

      Ops.alert(Ops.health(stalled))

      assert_email_sent(fn email ->
        assert email.subject == "Bitblocks: index stalled"
        assert email.text_body =~ "No block has completed since 2026-11-04T10:00:00Z"
        assert email.text_body =~ "Complete through block 162000 of 958900 known"
      end)
    end

    test "health from live state reads the snapshot without failing" do
      assert %{status: _, index: %{stalled: _}} = Ops.health()
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

  describe "a halted fork (#34)" do
    test "is a problem, with the height, and the health line says so" do
      h = Ops.health(%{node: %{"blocks" => 10}, overview: %{}, now: @now, halted: 501})

      assert "reorg_halted" in h.problems
      assert h.index.halted_at == 501

      assert BitblocksWeb.HealthLine.progress_text(h) =~
               "Tip sync has halted at block 501: a fork deeper than 10 blocks needs an operator."
    end
  end
end
