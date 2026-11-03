defmodule Bitblocks.ChainTiles do
  @moduledoc """
  Precomputed tiles of the whole chain for the scrubber (#48).

  Reads `blocks` only (height, time, size, num_tx, sync_state), in height-range
  batches of 1,024 on the unique height index; never `transactions`. Each
  leaf tile is encoded by `Bitblocks.ChainTiles.Codec`, content-hashed, and
  stored in `chain_tiles` only when its hash changed, then written through
  to `Bitblocks.ChainTiles.Cache` so requests read ETS only.

  Above the leaves sits a pyramid: level `L` buckets `32^L` blocks a record,
  so the whole chain at level 2 is one tile of about a thousand records, and
  the browser's first frame is that tile plus the manifest.

  Two modes:

  * `:full` walks every leaf from genesis to the tip and rebuilds the pyramid.
    An explicit `Bitblocks.Release.build_chain_tiles/1` task; never on deploy.
  * `:incremental` finds blocks whose `updated_at` moved since the last
    successful build (an index scan), rebuilds only the leaf tiles they fall
    in and those tiles' ancestors, and is a no-op when nothing changed or no
    full build exists yet. This is what the cron schedules.

  Unchanged input changes nothing. The tip tile changes only because its
  input (the tip) did.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.Block
  alias Bitblocks.ChainTiles.{Build, Cache, Codec, Tile}
  alias Bitblocks.Repo

  # Blocks committed just before the previous build started may carry an
  # updated_at older than its started_at; the overlap catches them.
  @watermark_overlap_seconds 120

  @type build_result :: {:ok, Build.t()} | {:ok, :noop} | {:ok, :no_full_build} | {:error, term()}

  @doc """
  Builds tiles. Options: `mode: :full | :incremental` (default `:incremental`),
  `tip:` (override the chain tip, tests).
  """
  @spec build(keyword()) :: build_result()
  def build(opts \\ []) do
    mode = Keyword.get(opts, :mode, :incremental)
    tip = Keyword.get_lazy(opts, :tip, &chain_tip/0)

    cond do
      tip == nil -> {:ok, :noop}
      mode == :full -> run(:full, tip, fn -> 0..(Codec.tile_count(0, tip) - 1) end)
      mode == :incremental -> incremental(tip)
    end
  end

  defp incremental(tip) do
    case watermark() do
      nil ->
        Logger.info("chain tiles: no full build yet; run Bitblocks.Release.build_chain_tiles()")
        {:ok, :no_full_build}

      since ->
        case dirty_leaf_indices(since) do
          [] -> {:ok, :noop}
          indices -> run(:incremental, tip, fn -> indices end)
        end
    end
  end

  defp run(mode, tip, leaf_indices_fun) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)

    build =
      Repo.insert!(%Build{
        mode: Atom.to_string(mode),
        status: "running",
        started_at: started_at,
        tip_height: tip
      })

    try do
      leaf_indices = leaf_indices_fun.() |> Enum.filter(&(&1 < Codec.tile_count(0, tip)))

      leaf_stats =
        Enum.reduce(leaf_indices, %{written: 0, unchanged: 0}, &build_leaf(&1, tip, &2))

      {ancestor_stats, _} =
        Enum.reduce(1..Codec.max_level(), {%{written: 0, unchanged: 0}, leaf_indices}, fn level,
                                                                                          {stats,
                                                                                           child_indices} ->
          indices =
            child_indices
            |> Enum.map(&div(&1, Codec.fan_out()))
            |> Enum.uniq()
            |> Enum.filter(&(&1 < Codec.tile_count(level, tip)))

          {Enum.reduce(indices, stats, &build_bucket_tile(level, &1, tip, &2)), indices}
        end)

      prune_beyond_tip(tip)
      if leaf_stats.written + ancestor_stats.written > 0, do: Cache.notify_changed()

      finished =
        build
        |> Ecto.Changeset.change(%{
          status: "ok",
          finished_at: DateTime.utc_now() |> DateTime.truncate(:second),
          tiles_written: leaf_stats.written + ancestor_stats.written,
          tiles_unchanged: leaf_stats.unchanged + ancestor_stats.unchanged,
          leaves_scanned: length(leaf_indices)
        })
        |> Repo.update!()

      Logger.info(
        "chain tiles #{mode} build ok: #{finished.leaves_scanned} leaves scanned, " <>
          "#{finished.tiles_written} tiles written, #{finished.tiles_unchanged} unchanged, tip #{tip}"
      )

      {:ok, finished}
    rescue
      exception ->
        build
        |> Ecto.Changeset.change(%{
          status: "failed",
          finished_at: DateTime.utc_now() |> DateTime.truncate(:second),
          error: Exception.message(exception)
        })
        |> Repo.update!()

        Logger.error("chain tiles #{mode} build failed: #{Exception.message(exception)}")
        {:error, exception}
    end
  end

  # -- Leaves ------------------------------------------------------------------

  @doc "The level-0 records for tile `idx`: one per height, missing rows as state 0."
  @spec leaf_records(non_neg_integer(), non_neg_integer()) :: [Codec.leaf()]
  def leaf_records(idx, tip) do
    first = Codec.first_height(0, idx)
    last = min(first + Codec.tile_records() - 1, tip)

    rows =
      from(b in Block,
        where: b.height >= ^first and b.height <= ^last,
        select:
          {b.height, %{time: b.time, size: b.size, num_tx: b.num_tx, sync_state: b.sync_state}}
      )
      |> Repo.all()
      |> Map.new()

    for height <- first..last//1 do
      case Map.get(rows, height) do
        nil ->
          %{time: 0, size: 0, num_tx: 0, state: 0}

        row ->
          %{
            time: row.time || 0,
            size: row.size || 0,
            num_tx: row.num_tx || 0,
            state: Codec.state_code(row.sync_state)
          }
      end
    end
  end

  defp build_leaf(idx, tip, stats) do
    first = Codec.first_height(0, idx)
    leaves = leaf_records(idx, tip)
    store(0, idx, first, length(leaves), Codec.encode_leaf_tile(first, leaves), stats)
  end

  # -- Buckets -----------------------------------------------------------------

  defp build_bucket_tile(level, idx, tip, stats) do
    first = Codec.first_height(level, idx)
    buckets = bucket_records(level, idx, tip)

    store(
      level,
      idx,
      first,
      length(buckets),
      Codec.encode_bucket_tile(level, first, buckets),
      stats
    )
  end

  @doc "The bucket records for tile `idx` at `level`, rolled up from the stored level below."
  @spec bucket_records(1..3, non_neg_integer(), non_neg_integer()) :: [Codec.bucket()]
  def bucket_records(level, idx, tip) do
    child_level = level - 1
    first_child = idx * Codec.fan_out()
    child_indices = Enum.to_list(first_child..(first_child + Codec.fan_out() - 1))

    children =
      from(t in Tile, where: t.level == ^child_level and t.idx in ^child_indices)
      |> Repo.all()
      |> Map.new(&{&1.idx, &1})

    records =
      Enum.flat_map(child_indices, fn child_idx ->
        needed = records_in_tile(child_level, child_idx, tip)

        decoded =
          case Map.get(children, child_idx) do
            nil -> []
            tile -> decode_records(tile)
          end

        pad(decoded, needed, child_level)
      end)

    if child_level == 0, do: Codec.rollup_leaves(records), else: Codec.rollup_buckets(records)
  end

  defp decode_records(%Tile{bytes: bytes}) do
    {:ok, _header, records} = Codec.decode(bytes)
    records
  end

  defp pad(records, needed, child_level) do
    filler =
      if child_level == 0,
        do: %{time: 0, size: 0, num_tx: 0, state: 0},
        else: Codec.empty_bucket()

    records
    |> Enum.take(needed)
    |> Enum.concat(List.duplicate(filler, max(needed - length(records), 0)))
  end

  @doc "How many records tile `idx` at `level` holds when the chain tip is `tip`."
  @spec records_in_tile(0..3, non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def records_in_tile(level, idx, tip) do
    first = Codec.first_height(level, idx)
    remaining = tip + 1 - first

    remaining
    |> Kernel./(Codec.span(level))
    |> Float.ceil()
    |> trunc()
    |> max(0)
    |> min(Codec.tile_records())
  end

  # -- Storage -----------------------------------------------------------------

  defp store(level, idx, first_height, count, bytes, stats) do
    hash = Codec.content_hash(bytes)

    existing =
      from(t in Tile, where: t.level == ^level and t.idx == ^idx, select: t.hash) |> Repo.one()

    if existing == hash do
      if Cache.fetch(level, idx) == :miss,
        do: Cache.put(Repo.get_by!(Tile, level: level, idx: idx))

      %{stats | unchanged: stats.unchanged + 1}
    else
      tile = %Tile{
        level: level,
        idx: idx,
        first_height: first_height,
        count: count,
        hash: hash,
        bytes: bytes,
        built_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      Repo.insert!(tile,
        on_conflict: {:replace, [:first_height, :count, :hash, :bytes, :built_at]},
        conflict_target: [:level, :idx]
      )

      Cache.put(tile)
      %{stats | written: stats.written + 1}
    end
  end

  # A reorg can only shorten the chain by a few blocks, but a test (or a reset
  # database) can move the tip back a long way; tiles past it are stale.
  defp prune_beyond_tip(tip) do
    for level <- 0..Codec.max_level() do
      last_idx = Codec.tile_count(level, tip) - 1

      from(t in Tile, where: t.level == ^level and t.idx > ^last_idx, select: t.idx)
      |> Repo.all()
      |> Enum.each(fn idx ->
        Repo.delete_all(from(t in Tile, where: t.level == ^level and t.idx == ^idx))
        Cache.delete(level, idx)
      end)
    end
  end

  # -- Reads -------------------------------------------------------------------

  @doc "The highest block height we hold, or nil with no blocks."
  @spec chain_tip() :: non_neg_integer() | nil
  def chain_tip, do: Repo.one(from(b in Block, select: max(b.height)))

  @doc "The last successful build, or nil."
  @spec last_build() :: Build.t() | nil
  def last_build do
    Repo.one(
      from(b in Build,
        where: b.status == "ok",
        order_by: [desc: b.started_at, desc: b.id],
        limit: 1
      )
    )
  end

  @doc "Recent builds, newest first."
  @spec list_builds(pos_integer()) :: [Build.t()]
  def list_builds(limit \\ 10) do
    Repo.all(from(b in Build, order_by: [desc: b.started_at, desc: b.id], limit: ^limit))
  end

  @doc "Where the next incremental build scans from, or nil before the first full build."
  @spec watermark() :: DateTime.t() | nil
  def watermark do
    case last_build() do
      nil -> nil
      %Build{started_at: at} -> DateTime.add(at, -@watermark_overlap_seconds, :second)
    end
  end

  @doc """
  Leaf tile indices holding a block whose `updated_at` is after `since`.
  One range scan on `blocks (updated_at)`; empty when nothing changed.
  """
  @spec dirty_leaf_indices(DateTime.t()) :: [non_neg_integer()]
  def dirty_leaf_indices(%DateTime{} = since) do
    since_naive = since |> DateTime.to_naive()

    from(b in Block, where: b.updated_at > ^since_naive, select: b.height, distinct: true)
    |> Repo.all()
    |> Enum.map(&Codec.tile_index(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Counts of stored tiles per level."
  @spec tile_counts() :: %{non_neg_integer() => non_neg_integer()}
  def tile_counts do
    from(t in Tile, group_by: t.level, select: {t.level, count(t.idx)})
    |> Repo.all()
    |> Map.new()
  end
end
