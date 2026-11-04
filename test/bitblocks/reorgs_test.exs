defmodule Bitblocks.ReorgsTest do
  use Bitblocks.DataCase, async: true

  alias Bitblocks.Reorgs
  alias Bitblocks.Reorgs.Reorg

  @now ~U[2026-10-31 12:00:00Z]

  test "records a resolved reorg as an annotation at that height" do
    assert {:ok, reorg} =
             Reorgs.record_observed(
               %{
                 fork_height: 900_000,
                 fork_point: 899_998,
                 orphan_count: 2,
                 outcome: "resolved"
               },
               @now
             )

    assert reorg.fork_height == 900_000
    assert reorg.fork_point == 899_998
    assert reorg.orphan_count == 2
    assert reorg.outcome == "resolved"
    assert reorg.detected_at == @now
    assert reorg.summary =~ "900000"
    assert reorg.summary =~ "899998"
    assert reorg.summary =~ "2 blocks"
  end

  test "records a deep reorg as still needing a person" do
    assert {:ok, reorg} =
             Reorgs.record_observed(
               %{
                 fork_height: 900_010,
                 fork_point: nil,
                 orphan_count: nil,
                 outcome: "needs_attention"
               },
               @now
             )

    assert reorg.outcome == "needs_attention"
    assert reorg.summary =~ "deeper than 10 blocks"
    assert reorg.summary =~ "900010"
  end

  test "a repeat of the same fork within the window updates the existing row" do
    attrs = %{
      fork_height: 900_000,
      fork_point: 899_998,
      orphan_count: 2,
      outcome: "resolved"
    }

    assert {:ok, first} = Reorgs.record_observed(attrs, @now)
    later = DateTime.add(@now, 30 * 60, :second)
    assert {:ok, second} = Reorgs.record_observed(attrs, later)

    assert second.id == first.id
    assert second.last_seen_at == later
    assert second.detected_at == @now
    assert Repo.aggregate(Reorg, :count) == 1
  end

  test "a different height is a new annotation" do
    attrs = %{fork_height: 900_000, fork_point: 899_999, orphan_count: 1, outcome: "resolved"}

    assert {:ok, _} = Reorgs.record_observed(attrs, @now)

    assert {:ok, other} =
             Reorgs.record_observed(%{attrs | fork_height: 900_005, orphan_count: 6}, @now)

    assert other.fork_height == 900_005
    assert Repo.aggregate(Reorg, :count) == 2
  end

  test "the notice stays up while a deep fork is still being seen" do
    {:ok, reorg} =
      Reorgs.record_observed(
        %{fork_height: 10, fork_point: nil, orphan_count: nil, outcome: "needs_attention"},
        @now
      )

    seen_at = DateTime.add(@now, 30 * 60, :second)

    assert Reorgs.active_notice(seen_at).id == reorg.id
  end

  test "a deep fork that stops being reported drops off the notice" do
    {:ok, _} =
      Reorgs.record_observed(
        %{fork_height: 10, fork_point: nil, orphan_count: nil, outcome: "needs_attention"},
        @now
      )

    stale = DateTime.add(@now, 3 * 3600, :second)

    assert Reorgs.active_notice(stale) == nil
    assert length(Reorgs.list_reorgs()) == 1
  end

  test "a resolved reorg stays on the notice for a day" do
    {:ok, reorg} =
      Reorgs.record_observed(
        %{fork_height: 10, fork_point: 8, orphan_count: 2, outcome: "resolved"},
        @now
      )

    assert Reorgs.active_notice(DateTime.add(@now, 23 * 3600, :second)).id == reorg.id
    assert Reorgs.active_notice(DateTime.add(@now, 25 * 3600, :second)) == nil
  end

  test "the timeline is highest height first" do
    {:ok, lower} =
      Reorgs.record_observed(
        %{fork_height: 100, fork_point: 99, orphan_count: 1, outcome: "resolved"},
        @now
      )

    {:ok, higher} =
      Reorgs.record_observed(
        %{fork_height: 200, fork_point: 190, orphan_count: 10, outcome: "resolved"},
        DateTime.add(@now, 60, :second)
      )

    assert Enum.map(Reorgs.list_reorgs(), & &1.id) == [higher.id, lower.id]
  end

  test "resolving a fork clears its needs-attention notice at once" do
    {:ok, _} =
      Reorgs.record_observed(
        %{fork_height: 957_302, fork_point: nil, orphan_count: nil, outcome: "needs_attention"},
        @now
      )

    later = DateTime.add(@now, 10 * 60, :second)

    {:ok, resolved} =
      Reorgs.record_observed(
        %{fork_height: 957_302, fork_point: 957_300, orphan_count: 1, outcome: "resolved"},
        later
      )

    assert Reorgs.active_notice(DateTime.add(later, 60, :second)).id == resolved.id
  end
end
