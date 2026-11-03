defmodule Bitblocks.ChainTiles.Cache do
  @moduledoc """
  The in-memory copy of every chain tile, so a tile request reads ETS and
  never the database.

  The builder writes through (`put/1`) as it stores each tile, on the node
  that ran the build. Every node, including the others in a rolling
  deployment, reconciles with `chain_tiles` off the request path: at boot,
  when a build finishes (`Bitblocks.PubSub` topic `chain_tiles`), and every
  `reconcile_ms` (default five minutes). A reconcile reads the ~1,000
  `(level, idx, hash)` rows, then only the tiles whose hash differs. A boot
  before `bin/migrate` has created the table logs a warning and the next
  reconcile fills the cache. All of this is off unless
  `config :bitblocks, Bitblocks.ChainTiles, warm_on_boot: true` (tests turn
  it off and drive the cache directly). Whole-chain tiles are ~20 MB.

  The manifest (which tiles exist and their content hashes) is derived from
  the cache and memoised until the next `put/1` or `delete/2`.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Bitblocks.ChainTiles.Tile
  alias Bitblocks.Repo

  @table :chain_tiles_cache
  @manifest_key :__manifest__
  @topic "chain_tiles"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    config = Application.get_env(:bitblocks, Bitblocks.ChainTiles, [])

    if Keyword.get(config, :warm_on_boot, true) do
      Phoenix.PubSub.subscribe(Bitblocks.PubSub, @topic)

      {:ok, %{reconcile_ms: Keyword.get(config, :reconcile_ms, :timer.minutes(5))},
       {:continue, :warm}}
    else
      {:ok, %{reconcile_ms: nil}}
    end
  end

  @impl true
  def handle_continue(:warm, state) do
    Task.start(fn -> reconcile() end)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    Task.start(fn -> reconcile() end)
    schedule(state)
    {:noreply, state}
  end

  def handle_info({:chain_tiles, :changed, node}, state) do
    if node != Node.self(), do: Task.start(fn -> reconcile() end)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(%{reconcile_ms: ms}) when is_integer(ms),
    do: Process.send_after(self(), :reconcile, ms)

  defp schedule(_state), do: :ok

  @doc "Tells every node's cache that the stored tiles changed."
  @spec notify_changed() :: :ok
  def notify_changed do
    Phoenix.PubSub.broadcast(Bitblocks.PubSub, @topic, {:chain_tiles, :changed, Node.self()})
  end

  @doc """
  Brings the cache in line with `chain_tiles`: loads tiles whose stored hash
  differs from the cached one (or that are not cached), drops tiles the
  table no longer has. Returns the number of tiles loaded.
  """
  @spec reconcile() :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile do
    stored = from(t in Tile, select: {{t.level, t.idx}, t.hash}) |> Repo.all() |> Map.new()
    cached = Map.new(all(), &{{&1.level, &1.idx}, &1.hash})

    stale = for {key, hash} <- stored, Map.get(cached, key) != hash, do: key
    gone = for {key, _} <- cached, not Map.has_key?(stored, key), do: key

    Enum.each(gone, fn {level, idx} -> delete(level, idx) end)

    stale
    |> Enum.chunk_every(100)
    |> Enum.each(fn keys ->
      levels = Enum.map(keys, &elem(&1, 0)) |> Enum.uniq()
      idxs = Enum.map(keys, &elem(&1, 1)) |> Enum.uniq()

      from(t in Tile, where: t.level in ^levels and t.idx in ^idxs)
      |> Repo.all()
      |> Enum.filter(&({&1.level, &1.idx} in keys))
      |> Enum.each(&put/1)
    end)

    if stale != [] or gone != [],
      do:
        Logger.info(
          "chain tiles cache reconciled: #{length(stale)} loaded, #{length(gone)} dropped"
        )

    {:ok, length(stale)}
  rescue
    exception ->
      Logger.warning("chain tiles cache not reconciled: #{Exception.message(exception)}")
      {:error, exception}
  end

  @doc "Loads every stored tile into the cache (a reconcile from empty)."
  @spec warm() :: {:ok, non_neg_integer()} | {:error, term()}
  def warm, do: reconcile()

  @doc "Stores a tile in the cache and invalidates the manifest."
  @spec put(Tile.t()) :: :ok
  def put(%Tile{} = tile) do
    :ets.insert(@table, {{tile.level, tile.idx}, tile})
    :ets.delete(@table, @manifest_key)
    :ok
  end

  @doc "Removes a tile from the cache."
  @spec delete(non_neg_integer(), non_neg_integer()) :: :ok
  def delete(level, idx) do
    :ets.delete(@table, {level, idx})
    :ets.delete(@table, @manifest_key)
    :ok
  end

  @doc "A cached tile, or `:miss`. Reads ETS only."
  @spec fetch(non_neg_integer(), non_neg_integer()) :: {:ok, Tile.t()} | :miss
  def fetch(level, idx) do
    case :ets.lookup(@table, {level, idx}) do
      [{_, %Tile{} = tile}] -> {:ok, tile}
      [] -> :miss
    end
  end

  @doc "Every cached tile, unordered, without a database read."
  @spec all() :: [Tile.t()]
  def all do
    :ets.select(@table, [{{{:"$1", :"$2"}, :"$3"}, [], [:"$3"]}])
  end

  @doc "Empties the cache (tests)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  The manifest the client fetches first: tip height, build time, and per
  level the content hash of every tile (`nil` where none is stored).
  Memoised in ETS until the next write.
  """
  @spec manifest() :: map() | nil
  def manifest do
    case :ets.lookup(@table, @manifest_key) do
      [{_, manifest}] ->
        manifest

      [] ->
        manifest = build_manifest(all())
        if manifest, do: :ets.insert(@table, {@manifest_key, manifest})
        manifest
    end
  end

  defp build_manifest([]), do: nil

  defp build_manifest(tiles) do
    alias Bitblocks.ChainTiles.Codec

    by_level = Enum.group_by(tiles, & &1.level)
    leaves = Map.get(by_level, 0, [])

    tip =
      leaves
      |> Enum.map(&(&1.first_height + &1.count - 1))
      |> Enum.max(fn -> -1 end)

    built_at =
      tiles
      |> Enum.map(&DateTime.to_unix(&1.built_at))
      |> Enum.max()

    levels =
      for level <- 0..Codec.max_level(), Map.has_key?(by_level, level) do
        level_tiles = Map.fetch!(by_level, level)
        last_idx = level_tiles |> Enum.map(& &1.idx) |> Enum.max()
        by_idx = Map.new(level_tiles, &{&1.idx, &1.hash})

        %{
          level: level,
          span: Codec.span(level),
          tiles: for(idx <- 0..last_idx, do: Map.get(by_idx, idx))
        }
      end

    %{
      version: 1,
      tip_height: tip,
      built_at: built_at,
      tile_records: Codec.tile_records(),
      fan_out: Codec.fan_out(),
      levels: levels
    }
  end
end
