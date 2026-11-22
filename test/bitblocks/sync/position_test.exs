defmodule Bitblocks.Sync.PositionTest do
  # The snapshot table and the Position config are VM-global.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.SyncProgress
  alias Bitblocks.Sync.Position

  setup do
    previous = Application.get_env(:bitblocks, Position)

    on_exit(fn ->
      Application.put_env(:bitblocks, Position, previous)
      Position.reset()
      :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()})
    end)

    Application.put_env(:bitblocks, Position, source: :memory, ttl_ms: 60_000)
    Position.reset()
    :ok
  end

  defp snapshot(attrs) do
    empty = SyncProgress.empty_snapshot()
    Map.merge(%{empty | updated_at: DateTime.utc_now()}, attrs)
  end

  defp block_queries(fun) do
    parent = self()
    ref = make_ref()
    handler = "position-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:bitblocks, :repo, :query],
      fn _, _, meta, _ -> if meta.source == "blocks", do: send(parent, {ref, :q}) end,
      nil
    )

    try do
      result = fun.()
      {result, count(ref, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp count(ref, n) do
    receive do
      {^ref, :q} -> count(ref, n + 1)
    after
      0 -> n
    end
  end

  describe "from_snapshot/1" do
    test "prefers the coordinator's overview, then the snapshot's own reload" do
      overview = %{SyncProgress.empty_snapshot().overview | our_tip: 90, complete_through: 80}

      assert {:ok, %{tip: 100, complete_through: 95}} =
               Position.from_snapshot(
                 snapshot(%{sync: %{tip: 100, complete_through: 95}, overview: overview})
               )

      assert {:ok, %{tip: 90, complete_through: 80}} =
               Position.from_snapshot(snapshot(%{overview: overview}))
    end

    test "a stale or empty snapshot is no answer" do
      overview = %{SyncProgress.empty_snapshot().overview | our_tip: 90, complete_through: 80}
      old = DateTime.add(DateTime.utc_now(), -600, :second)

      assert :none = Position.from_snapshot(snapshot(%{overview: overview, updated_at: old}))
      assert :none = Position.from_snapshot(SyncProgress.empty_snapshot())
    end
  end

  describe "position/1" do
    test "reads a fresh snapshot without asking the database" do
      overview = %{SyncProgress.empty_snapshot().overview | our_tip: 90, complete_through: 80}
      :ets.insert(SyncProgress, {:snapshot, snapshot(%{overview: overview})})

      assert {%{tip: 90, complete_through: 80}, 0} = block_queries(&Position.position/0)
    end

    test "with no snapshot, asks the database once per ttl" do
      for h <- 0..4, do: block_fixture(%{height: h, sync_state: "completed"})

      {first, asked} = block_queries(&Position.position/0)
      assert first == %{tip: 4, complete_through: 4}
      assert asked > 0

      block_fixture(%{height: 5, sync_state: "completed"})

      # Within the ttl the copy stands: the lag the moduledoc states.
      assert {^first, 0} = block_queries(&Position.position/0)

      # fresh: true is the strict path.
      assert {%{tip: 5, complete_through: 5}, _} =
               block_queries(fn -> Position.position(fresh: true) end)
    end

    test "source: :database asks every time" do
      Application.put_env(:bitblocks, Position, source: :database)
      overview = %{SyncProgress.empty_snapshot().overview | our_tip: 90, complete_through: 80}
      :ets.insert(SyncProgress, {:snapshot, snapshot(%{overview: overview})})

      block_fixture(%{height: 0, sync_state: "completed"})

      assert {%{tip: 0, complete_through: 0}, asked} = block_queries(&Position.position/0)
      assert asked > 0
    end
  end
end
