defmodule Bitblocks.Workers.FlowTilesWorkerTest do
  use Bitblocks.DataCase, async: false

  alias Bitblocks.ChainTiles.Cache
  alias Bitblocks.FlowTiles
  alias Bitblocks.Workers.FlowTilesWorker

  setup do
    Cache.clear()
    on_exit(fn -> Cache.clear() end)
    :ok
  end

  test "the cron's run does nothing before a person starts a build" do
    assert FlowTilesWorker.perform(%Oban.Job{args: %{}}) == :ok
    assert FlowTiles.built_through() == nil
  end
end
