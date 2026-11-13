defmodule Bitblocks.FlowTiles do
  @moduledoc """
  Precomputed per-block flow summaries for the `/tx-graph` far view (#67):
  ranges past `ChainFlow.max_txs/0` draw one node per block (or per group of
  blocks) and an arc per age bin of the coins its inputs spend, read from
  binary tiles in ETS, so a tile request never queries `transactions`.

  A block's summary is fixed once the block is `completed` and every block
  below it is: its inputs spend outputs of earlier blocks, which are stored.
  So the builder walks upward from where it stopped to
  `Sync.complete_through/0` and never revisits a block (a reorg below the
  built height, or a block reopened there, needs `build(from: h)`).
  What later spends a block's outputs is not in its summary: that changes
  with every later block, and the near view (`Bitblocks.ChainFlow`) shows it.

  Storage: the `chain_tiles` table at level 100, so the tiles share
  `Bitblocks.ChainTiles.Cache` (ETS, warmed at boot, written through,
  reconciled across nodes) with the chain scrubber's. 96 bytes a block:
  about 38 MB for 400,000 blocks, the same in ETS.

  Reads per batch of about `@batch_txs` txs: the blocks rows, one grouped
  tally over `transactions` on the height index, and one grouped join of
  `spend_index` (by `spending_txid`) to the source rows (by `txid`) for the
  ages. A run stops at its time budget and says whether it is behind.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.Block
  alias Bitblocks.ChainTiles.{Cache, Tile}
  alias Bitblocks.FlowTiles.Codec
  alias Bitblocks.Repo

  @level 100
  @batch_txs 20_000
  @budget_ms 120_000
  @statement_timeout_ms 120_000
  @max_blocks 100_000

  @doc "The `chain_tiles.level` flow tiles are stored at."
  def level, do: @level

  @doc "The most blocks `/tx-graph` opens at once from flow tiles."
  def max_blocks, do: @max_blocks

  @doc """
  Builds flow tiles upward. Options:

    * `from:` start (or rebuild) at this height; without it, resume after
      the highest height built, and do nothing before a first build.
    * `through:` stop at this height (default `Sync.complete_through/0`).
    * `budget_ms:` stop after this long (default two minutes), at a block
      boundary, with what was built written.

  Returns `{:ok, :not_started}`, `{:ok, :noop}` or
  `{:ok, %{from:, through:, blocks:, tiles_written:, behind:}}`.
  """
  @spec build(keyword()) :: {:ok, atom() | map()} | {:error, term()}
  def build(opts \\ []) do
    through = Keyword.get_lazy(opts, :through, &complete_through/0)

    start =
      case Keyword.fetch(opts, :from) do
        {:ok, h} when is_integer(h) and h >= 0 -> h
        _ -> if built = built_through(), do: built + 1, else: :not_started
      end

    cond do
      start == :not_started ->
        {:ok, :not_started}

      not is_integer(through) or start > through ->
        {:ok, :noop}

      true ->
        deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, @budget_ms)
        run(start, through, deadline)
    end
  rescue
    exception ->
      Logger.error("flow tiles build failed: #{Exception.message(exception)}")
      {:error, exception}
  end

  defp run(start, through, deadline) do
    result =
      Enum.reduce_while(
        Codec.tile_index(start)..Codec.tile_index(through)//1,
        %{from: start, through: start - 1, blocks: 0, tiles_written: 0, behind: false},
        fn idx, acc ->
          if acc.blocks > 0 and System.monotonic_time(:millisecond) >= deadline do
            {:halt, %{acc | behind: true}}
          else
            first = Codec.first_height(idx)
            last = min(first + Codec.tile_records() - 1, through)
            {built_to, written} = build_tile(idx, max(start, first), last, deadline)

            acc = %{
              acc
              | through: built_to,
                blocks: acc.blocks + (built_to - max(start, first) + 1),
                tiles_written: acc.tiles_written + written
            }

            if built_to < last, do: {:halt, %{acc | behind: true}}, else: {:cont, acc}
          end
        end
      )

    result = %{result | behind: result.behind or result.through < through}
    if result.tiles_written > 0, do: Cache.notify_changed()

    Logger.info(
      "flow tiles built #{result.from}..#{result.through} (#{result.tiles_written} tiles)" <>
        if(result.behind, do: ", behind #{through}", else: "")
    )

    {:ok, result}
  end

  # Records for heights from..last of tile idx, keeping the stored records
  # below `from`. Returns the last height built and tiles written (0 or 1).
  defp build_tile(idx, from, last, deadline) do
    first = Codec.first_height(idx)

    kept =
      case Repo.one(from(t in Tile, where: t.level == @level and t.idx == ^idx)) do
        %Tile{bytes: bytes} ->
          {:ok, _, records} = Codec.decode(bytes)
          Enum.take(records, from - first)

        nil ->
          []
      end

    kept = kept ++ List.duplicate(Codec.empty(), from - first - length(kept))

    {fresh, built_to} = build_records(from, last, deadline)

    if fresh == [] do
      {from - 1, 0}
    else
      store(idx, first, kept ++ fresh)
      {built_to, 1}
    end
  end

  defp build_records(from, last, deadline) do
    blocks =
      Repo.all(
        from(b in Block,
          where: b.height >= ^from and b.height <= ^last,
          select: {b.height, %{time: b.time, num_tx: b.num_tx}}
        )
      )
      |> Map.new()

    from..last
    |> Enum.chunk_while(
      {[], 0},
      fn h, {batch, txs} ->
        txs = txs + (get_in(blocks, [h, :num_tx]) || 1)

        if txs >= @batch_txs,
          do: {:cont, Enum.reverse([h | batch]), {[], 0}},
          else: {:cont, {[h | batch], txs}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {batch, _} -> {:cont, Enum.reverse(batch), {[], 0}}
      end
    )
    |> Enum.reduce_while({[], from - 1}, fn batch, {acc, _built_to} = state ->
      if acc != [] and System.monotonic_time(:millisecond) >= deadline do
        {:halt, state}
      else
        records = batch_records(hd(batch), List.last(batch), blocks)
        {:cont, {acc ++ records, List.last(batch)}}
      end
    end)
  end

  @doc "The summary records for heights `a..b`, one per height."
  @spec batch_records(non_neg_integer(), non_neg_integer(), map()) :: [Codec.record()]
  def batch_records(a, b, blocks) do
    {:ok, {tallies, ages}} =
      Bitblocks.ChainScrubber.with_statement_timeout(@statement_timeout_ms, fn ->
        {tallies(a, b), ages(a, b)}
      end)
      |> case do
        {:ok, _} = ok -> ok
        {:error, reason} -> raise "flow tile read #{a}..#{b}: #{reason}"
      end

    for h <- a..b do
      block = Map.get(blocks, h, %{})
      t = Map.get(tallies, h, %{stored: 0, n_in: 0, n_out: 0, sats_out: 0})
      by_bin = Map.get(ages, h, %{})
      binned = by_bin |> Map.values() |> Enum.sum()

      %{
        time: block[:time] || 0,
        num_tx: block[:num_tx] || t.stored,
        stored: t.stored,
        n_in: t.n_in,
        n_out: t.n_out,
        unknown: max(t.n_in - binned, 0),
        sats_out: t.sats_out,
        hist: for(bin <- 0..(Codec.age_bins() - 1), do: Map.get(by_bin, bin, 0))
      }
    end
  end

  defp tallies(a, b) do
    Repo.all(
      from(t in "transactions",
        where: t.block_height >= ^a and t.block_height <= ^b,
        group_by: t.block_height,
        select:
          {t.block_height,
           %{
             stored: count(),
             # A tx with no input txids is a coinbase: its one input spends nothing.
             n_in:
               fragment(
                 "coalesce(sum(CASE WHEN coalesce(cardinality(?), 0) = 0 THEN 0 ELSE coalesce(cardinality(?), 0) END), 0)::bigint",
                 t.input_txids,
                 t.inputs
               ),
             n_out: fragment("coalesce(sum(coalesce(cardinality(?), 0)), 0)::bigint", t.outputs),
             sats_out:
               fragment(
                 "CASE WHEN count(?) = count(*) THEN coalesce(sum(?), 0) ELSE -1 END::bigint",
                 t.total_output_satoshis,
                 t.total_output_satoshis
               )
           }}
      )
    )
    |> Map.new()
  end

  # height => %{age bin => inputs}, from spend_index rows whose source is stored.
  defp ages(a, b) do
    Repo.all(
      from(t in "transactions",
        join: s in "spend_index",
        on: s.spending_txid == t.txid,
        join: src in "transactions",
        on: src.txid == s.txid,
        where: t.block_height >= ^a and t.block_height <= ^b and not is_nil(src.block_height),
        group_by: [t.block_height, src.block_height],
        select: {t.block_height, src.block_height, count()}
      )
    )
    |> Enum.reduce(%{}, fn {h, src_h, n}, acc ->
      bin = Codec.age_bin(h - src_h)
      Map.update(acc, h, %{bin => n}, &Map.update(&1, bin, n, fn m -> m + n end))
    end)
  end

  defp store(idx, first, records) do
    bytes = Codec.encode(first, records)

    tile = %Tile{
      level: @level,
      idx: idx,
      first_height: first,
      count: length(records),
      hash: Codec.content_hash(bytes),
      bytes: bytes,
      built_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Repo.insert!(tile,
      on_conflict: {:replace, [:first_height, :count, :hash, :bytes, :built_at]},
      conflict_target: [:level, :idx]
    )

    Cache.put(tile)
  end

  # -- Reads -------------------------------------------------------------------

  @doc "The highest height built, from the table, or nil before a first build."
  @spec built_through() :: integer() | nil
  def built_through do
    Repo.one(
      from(t in Tile,
        where: t.level == @level and t.count > 0,
        select: max(t.first_height + t.count - 1)
      )
    )
  end

  @doc "Stored flow tiles and the height they reach."
  def status do
    %{
      tiles: Repo.one(from(t in Tile, where: t.level == @level, select: count())),
      built_through: built_through(),
      complete_through: complete_through(),
      cached: Cache.all() |> Enum.count(&(&1.level == @level))
    }
  end

  defp complete_through do
    Bitblocks.Sync.complete_through()
  rescue
    _ -> nil
  end
end
