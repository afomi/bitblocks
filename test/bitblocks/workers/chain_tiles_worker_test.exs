defmodule Bitblocks.Workers.ChainTilesWorkerTest do
  @moduledoc """
  The scheduled tile build is a no-op until a person runs a full build, and
  runs on its own queue (#48).
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainTileFixtures

  alias Bitblocks.ChainTiles
  alias Bitblocks.ChainTiles.Cache
  alias Bitblocks.Workers.ChainTilesWorker

  setup do
    Cache.clear()
    :ok
  end

  test "the incremental cron job does nothing before a full build" do
    insert_blocks(0..100)
    assert :ok = perform_job(ChainTilesWorker, %{"mode" => "incremental"})
    assert ChainTiles.tile_counts() == %{}
    assert ChainTiles.list_builds() == []
  end

  test "a full job builds; the next incremental is a no-op" do
    insert_blocks(0..100)
    assert :ok = perform_job(ChainTilesWorker, %{"mode" => "full"})
    assert ChainTiles.tile_counts() == %{0 => 1, 1 => 1, 2 => 1, 3 => 1}
    assert :ok = perform_job(ChainTilesWorker, %{"mode" => "incremental"})
    assert length(ChainTiles.list_builds()) == 1
  end

  test "runs on the chain_tiles queue, apart from the tx lanes, one at a time" do
    assert ChainTilesWorker.__opts__()[:queue] == :chain_tiles
    assert ChainTilesWorker.__opts__()[:max_attempts] == 1
    # Test config turns queues off; the shared config declares the lane.
    assert File.read!("config/config.exs") =~ ~r/queues: \[[^\]]*\bchain_tiles: 1/s

    crontab =
      Enum.find_value(Application.fetch_env!(:bitblocks, Oban)[:plugins], fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert Enum.any?(crontab, fn
             {_, ChainTilesWorker, args: %{"mode" => "incremental"}} -> true
             _ -> false
           end)

    refute Enum.any?(crontab, fn
             {_, ChainTilesWorker, args: %{"mode" => "full"}} -> true
             _ -> false
           end)
  end

  defp perform_job(worker, args) do
    Oban.Testing.perform_job(worker, args, repo: Bitblocks.Repo)
  end
end
