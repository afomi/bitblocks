defmodule Bitblocks.TipLane do
  @moduledoc """
  A tip lane (#139): one managed projection's slice of the chain, kept
  current at the tip while the contiguous sync is still far behind.
  See docs/SYNCING.md ("A tip lane for one projection").

  Each block from the lane's `from_height` up is read once from our node,
  by the same paths the sync uses: whole when it is within the raw-block cap
  (`Chain.RawBlock`), streamed otherwise (`Chain.BlockStream`), and checked
  the same way (header hash, tx count, merkleroot) before anything is kept.
  From it the lane keeps only the txs that match the projection's filter,
  plus the txs that spend an output of the slice (a match from `from_height`
  on, or earlier in the same block), and stores them through the one ingest
  path (`Chain.TxIngest.store_chunk/2`, the whole tx pipeline). So its
  storage is the size of the slice.

  It never marks a block `completed` and never moves `complete_through`:
  the sync owns both. When the sync reaches a block the lane read, it finds
  those txs already stored and skips them, as it does any stored tx.

  Coverage is computed, never stored: `through/2` is the last height `h`
  such that every block from the lane's `from_height` through `h` is
  `completed`, or read by this lane under the hash its header has now. A
  block whose hash changed (a reorg) is no longer covered: the lane removes
  the rows it kept from the orphan (`TxIngest.remove/2`) and reads the block
  that replaced it. Follow streams already get `reorg` from header sync.

  The lane takes one slot's worth of the RPC budget and never more: while a
  lane runs, the sync dispatches into at most `Sync.concurrency_limit/0`
  minus one slots (never fewer than one), and the lane reads a block only
  while the sync's live jobs leave a slot free. One block at a time, one
  request in flight, on its own Oban queue (`:tip_lane`, concurrency 1),
  and only on a writer node (`Bitblocks.NodeRole`).

  It ships dormant: nothing runs until `Release.start_tip_lane/2` starts a
  lane, and `Release.stop_tip_lane/1` stops it, keeping its rows.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.{Projections, Repo, Sync}
  alias Bitblocks.Chain.{Block, BlockStream, RawBlock, TxIngest}
  alias Bitblocks.Projections.Projection
  alias Bitblocks.TipLane.{Lane, LaneBlock}
  alias Bitblocks.TransactionParser

  @run_ms 50_000
  @chunk 100
  # The slice's own txs are held in memory to find spends of their outputs;
  # a filter that matches more than this isn't a slice.
  @max_slice_txs 200_000
  @max_backoff_minutes 60

  # The filter columns TransactionParser.analyze/1 computes; output_addresses
  # is read straight from the outputs' bytes.
  @analysis_columns ~w(protocols output_script_hashes output_template_hashes aip_signers)

  @doc "The PubSub topic a lane announces each block it has read on."
  @spec topic(integer()) :: String.t()
  def topic(projection_id), do: "tip_lane:#{projection_id}"

  @doc "The lane for a projection, or nil."
  @spec get(integer()) :: Lane.t() | nil
  def get(projection_id), do: Repo.get_by(Lane, projection_id: projection_id)

  @doc "True while any lane is running."
  @spec running?() :: boolean()
  def running?, do: Repo.exists?(from(l in Lane, where: l.status == "running"))

  @doc """
  The worker slots the sync may fill out of `n` while a lane runs: at most
  `Sync.concurrency_limit/0` minus the lane's one, never fewer than one.
  `n` unchanged when no lane runs.
  """
  @spec sync_slots(pos_integer()) :: pos_integer()
  def sync_slots(n) do
    if running?() do
      {limit, _} = Sync.concurrency_limit()
      n |> min(limit - 1) |> max(1)
    else
      n
    end
  end

  # -- Starting and stopping ---------------------------------------------------

  @doc """
  What starting a lane for `projection` from `from_height` would do, reading
  nothing from the node: how many blocks it would read from our stored
  headers, how many of them stream, what it keeps, and what it leaves the
  sync. `{:error, reason}` for a projection a lane can't serve.
  """
  @spec plan(Projection.t(), integer()) :: {:ok, map()} | {:error, term()}
  def plan(%Projection{} = projection, from_height) do
    with :ok <- check(projection, from_height) do
      tip = Projections.tip_height()
      complete_through = Sync.complete_through()
      {limit, binding} = Sync.concurrency_limit()
      chosen = Sync.concurrency()
      counts = block_counts(from_height, tip)

      {:ok,
       %{
         projection_id: projection.id,
         projection: "#{projection.tenant}/#{projection.name}",
         filter: projection.filter,
         from_height: from_height,
         tip_height: tip,
         complete_through: complete_through,
         blocks: counts.blocks,
         blocks_to_read: counts.to_read,
         blocks_completed: counts.completed,
         blocks_streamed: counts.streamed,
         slice_txs_stored: slice_count(projection, from_height),
         stores:
           "only txs matching #{Jason.encode!(projection.filter)}, plus txs spending their " <>
             "outputs; never marks a block completed or moves complete_through",
         reads: "each block once, one at a time, from our node (REST, else getblock)",
         sync_slots: %{
           now: chosen,
           while_running: chosen |> min(limit - 1) |> max(1),
           limit: limit,
           limit_reason: binding
         },
         lane: status(projection)
       }}
    end
  end

  @doc """
  Starts (or restarts) the lane for `projection` from `from_height`, and
  queues its first run. Rows kept by an earlier run stay.
  """
  @spec start(Projection.t(), integer()) :: {:ok, Lane.t()} | {:error, term()}
  def start(%Projection{} = projection, from_height) do
    with :ok <- check(projection, from_height) do
      now = now()

      lane =
        Repo.insert!(
          %Lane{
            projection_id: projection.id,
            from_height: from_height,
            status: "running",
            started_at: now,
            stopped_at: nil
          },
          on_conflict: [
            set: [
              from_height: from_height,
              status: "running",
              started_at: now,
              stopped_at: nil,
              updated_at: now
            ]
          ],
          conflict_target: :projection_id,
          returning: true
        )

      Oban.insert(Bitblocks.Workers.TipLaneWorker.new(%{}))
      {:ok, lane}
    end
  end

  @doc "Stops the lane for `projection`. Its rows, and what it read, stay."
  @spec stop(Projection.t()) :: {:ok, Lane.t()} | {:error, :no_lane}
  def stop(%Projection{id: id}) do
    case get(id) do
      nil ->
        {:error, :no_lane}

      lane ->
        lane
        |> Ecto.Changeset.change(status: "stopped", stopped_at: now())
        |> Repo.update()
    end
  end

  defp check(%Projection{source: source}, _from) when source != "transactions",
    do: {:error, :not_a_tx_projection}

  defp check(_projection, from) when not is_integer(from) or from < 0,
    do: {:error, :invalid_from_height}

  defp check(_projection, _from), do: :ok

  defp block_counts(from, tip) when not is_integer(tip) or tip < from,
    do: %{blocks: 0, to_read: 0, completed: 0, streamed: 0}

  defp block_counts(from, tip) do
    max_bytes = Application.get_env(:bitblocks, :raw_block_max_bytes, 32 * 1024 * 1024)
    max_txs = Application.get_env(:bitblocks, :raw_block_max_txs, 20_000)

    {completed, to_read, streamed} =
      Repo.one(
        from(b in Block,
          where: b.height >= ^from and b.height <= ^tip,
          select:
            {fragment("count(*) FILTER (WHERE ? = 'completed')", b.sync_state),
             fragment("count(*) FILTER (WHERE ? <> 'completed')", b.sync_state),
             fragment(
               "count(*) FILTER (WHERE ? <> 'completed' AND (? > ? OR ((? IS NULL OR ? <= 80) AND (? IS NULL OR ? <= 0 OR ? > ?))))",
               b.sync_state,
               b.size,
               ^max_bytes,
               b.size,
               b.size,
               b.num_tx,
               b.num_tx,
               b.num_tx,
               ^max_txs
             )}
        )
      )

    %{blocks: tip - from + 1, to_read: to_read, completed: completed, streamed: streamed}
  end

  defp slice_count(projection, from) do
    projection
    |> Projections.query()
    |> where([t], t.block_height >= ^from)
    |> select([t], count())
    |> Repo.one()
  end

  # -- Coverage ----------------------------------------------------------------

  @doc """
  How far `lane` reaches: the last height `h` such that every block from its
  `from_height` through `h` is completed, or read by this lane under the
  hash it has now. `from_height - 1` when the first block is neither.
  """
  @spec through(Lane.t(), integer() | nil) :: integer()
  def through(%Lane{} = lane, tip \\ Projections.tip_height()) do
    covered_through(
      lane.projection_id,
      lane.from_height,
      tip,
      Projections.completed_through(lane.from_height, tip)
    )
  end

  @doc """
  Extends `completed` (the last height with every block from `from` on
  completed) over the blocks projection `projection_id`'s lane has read
  under their current hash, up to `to`. Unchanged when the projection has
  no lane rows, or none just above `completed`.
  """
  @spec covered_through(integer(), integer(), integer() | nil, integer()) :: integer()
  def covered_through(_id, _from, to, completed) when not is_integer(to) or completed >= to,
    do: completed

  def covered_through(projection_id, _from, to, completed) do
    lowest =
      Repo.one(
        from(l in LaneBlock,
          where: l.projection_id == ^projection_id and l.status == "read",
          select: min(l.height)
        )
      )

    if is_integer(lowest) and lowest <= completed + 1 do
      %{rows: [[gap]]} =
        Repo.query!(
          """
          SELECT min(h) FROM generate_series($1::integer, $2::integer) AS h
          WHERE NOT EXISTS (
            SELECT 1 FROM blocks b
            WHERE b.height = h AND (
              b.sync_state = 'completed' OR EXISTS (
                SELECT 1 FROM tip_lane_blocks l
                WHERE l.projection_id = $3 AND l.height = h
                  AND l.block_hash = b.hash AND l.status = 'read'
              )
            )
          )
          """,
          [completed + 1, to, projection_id]
        )

      if gap, do: gap - 1, else: to
    else
      completed
    end
  end

  @doc """
  The lane for `projection`, as data for its status, or nil without one:
  `state` (running | stopped), `from_height`, `through_height`,
  `behind_blocks` (to the further of our tip and the node's), `next_height`,
  `waiting_on` (a sentence, nil at the tip), and what it has read and kept.
  """
  @spec status(Projection.t(), keyword()) :: map() | nil
  def status(%Projection{id: id}, opts \\ []) do
    case get(id) do
      nil ->
        nil

      lane ->
        tip = Keyword.get_lazy(opts, :tip, &Projections.tip_height/0)
        node_tip = Keyword.get(opts, :node_tip)
        through = through(lane, tip)
        head = [tip, node_tip] |> Enum.filter(&is_integer/1) |> Enum.max(fn -> nil end)

        {read, kept} =
          Repo.one(
            from(l in LaneBlock,
              where: l.projection_id == ^id and l.status == "read",
              select: {count(), fragment("coalesce(sum(cardinality(?)), 0)::bigint", l.txids)}
            )
          )

        %{
          state: lane.status,
          from_height: lane.from_height,
          through_height: through,
          behind_blocks: if(head, do: max(head - through, 0), else: 0),
          next_height: through + 1,
          waiting_on: waiting_on(lane, through),
          blocks_read: read,
          txs_kept: kept,
          started_at: lane.started_at,
          stopped_at: lane.stopped_at
        }
    end
  end

  defp waiting_on(%Lane{status: "stopped", stopped_at: at}, through) do
    "Stopped#{if at, do: " at #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}"}, " <>
      "through block #{through}; its rows stay."
  end

  defp waiting_on(%Lane{projection_id: id}, through) do
    height = through + 1

    case Repo.get_by(Block, height: height) do
      nil ->
        nil

      block ->
        case Repo.get_by(LaneBlock, projection_id: id, height: height) do
          %LaneBlock{status: "failed", block_hash: hash} = row when hash == block.hash ->
            "Block #{height} couldn't be read yet (#{row.error}; #{row.attempts} " <>
              "#{if row.attempts == 1, do: "try", else: "tries"}); the next try is at " <>
              "#{Calendar.strftime(next_try(row), "%H:%M UTC")}."

          %LaneBlock{status: "reading", block_hash: hash} = row when hash == block.hash ->
            "Block #{height} is being read now, since " <>
              "#{Calendar.strftime(row.started_at || now(), "%H:%M UTC")}."

          _ ->
            "Block #{height} is next to read."
        end
    end
  end

  # -- Running -----------------------------------------------------------------

  @doc """
  One run of every running lane, one block at a time, for up to `:run_ms`
  (#{@run_ms} ms) in all; the budget is checked between blocks, so a large
  streamed block is always read to its end. Returns `{:ok, [stats]}`, one per
  lane: blocks read, txs kept, and `stopped`: `:tip`, `:time`,
  `{:waiting, reason}` or `{height, reason}` for a block that couldn't be read.
  Nothing on a reader node.
  """
  @spec run(keyword()) :: {:ok, [map()]}
  def run(opts \\ []) do
    if Bitblocks.NodeRole.role() == :writer do
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :run_ms, @run_ms)

      stats =
        from(l in Lane, where: l.status == "running", order_by: l.id)
        |> Repo.all()
        |> Enum.map(&run_lane(&1, deadline))

      {:ok, stats}
    else
      {:ok, []}
    end
  end

  defp run_lane(lane, deadline) do
    stats = %{projection_id: lane.projection_id, read: 0, kept: 0}

    with %Projection{} = projection <- Projections.get(lane.projection_id),
         {:ok, slice} <- slice(projection, lane.from_height) do
      through = through(lane)
      ctx = %{lane: lane, projection: projection, slice: slice}
      stats = read_from(ctx, through + 1, deadline, stats)

      Logger.info(
        "tip lane ##{lane.projection_id}: read #{stats.read} blocks from #{through + 1}, " <>
          "kept #{stats.kept} txs, stopped: #{inspect(stats.stopped)}"
      )

      stats
    else
      nil -> Map.put(stats, :stopped, :no_projection)
      {:error, reason} -> Map.put(stats, :stopped, reason)
    end
  end

  # The slice's txids from `from` on, in internal byte order, for the spend check.
  defp slice(projection, from) do
    txids =
      projection
      |> Projections.query()
      |> where([t], t.block_height >= ^from)
      |> select([t], t.txid)
      |> limit(^(@max_slice_txs + 1))
      |> Repo.all()

    if length(txids) > @max_slice_txs,
      do: {:error, :slice_too_large},
      else: {:ok, MapSet.new(txids, &internal/1)}
  end

  defp read_from(ctx, height, deadline, stats) do
    with :ok <- before_deadline(deadline),
         %Block{} = block <- Repo.get_by(Block, height: height) || :tip do
      cond do
        covered?(ctx.lane, block) ->
          read_from(ctx, height + 1, deadline, stats)

        (waiting = waiting_for_sync(block)) != :go ->
          Map.put(stats, :stopped, {:waiting, waiting})

        true ->
          case backing_off(ctx.lane, block) do
            {:wait, until} ->
              Map.put(stats, :stopped, {height, {:backing_off, until}})

            :go ->
              case read_block(ctx, block) do
                {:ok, kept, matched} ->
                  ctx = %{ctx | slice: Enum.reduce(matched, ctx.slice, &MapSet.put(&2, &1))}
                  stats = %{stats | read: stats.read + 1, kept: stats.kept + kept}
                  read_from(ctx, height + 1, deadline, stats)

                {:error, reason} ->
                  Map.put(stats, :stopped, {height, reason})
              end
          end
      end
    else
      reason -> Map.put(stats, :stopped, reason)
    end
  end

  defp before_deadline(deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: :time, else: :ok
  end

  defp covered?(%Lane{}, %Block{sync_state: "completed"}), do: true

  defp covered?(%Lane{projection_id: id}, %Block{} = block) do
    Repo.exists?(
      from(l in LaneBlock,
        where:
          l.projection_id == ^id and l.height == ^block.height and l.block_hash == ^block.hash and
            l.status == "read"
      )
    )
  end

  # A block the sync is working is the sync's: it is read once, by the sync.
  # Otherwise the lane is one slot of the RPC budget: it reads only while the
  # sync's live block jobs leave one free (Sync.dispatch/1 leaves one while a
  # lane runs).
  defp waiting_for_sync(%Block{hash: hash, height: height}) do
    live = Sync.live_jobs()
    {limit, _} = Sync.concurrency_limit()

    cond do
      Enum.any?(live, &(hash in &1.held)) -> {:sync_owns_block, height}
      length(live) >= limit -> :rpc_budget
      true -> :go
    end
  end

  @doc false
  def next_try(%LaneBlock{status: "failed", attempts: n, read_at: at})
      when n > 0 and not is_nil(at),
      do: DateTime.add(at, min(Integer.pow(2, n - 1), @max_backoff_minutes) * 60, :second)

  def next_try(_row), do: nil

  defp backing_off(%Lane{projection_id: id}, block) do
    with %LaneBlock{block_hash: hash} = row when hash == block.hash <-
           Repo.get_by(LaneBlock, projection_id: id, height: block.height),
         %DateTime{} = until <- next_try(row),
         :gt <- DateTime.compare(until, DateTime.utc_now()) do
      {:wait, until}
    else
      _ -> :go
    end
  end

  @doc """
  Reads one block for `ctx`'s projection and keeps its slice:
  `{:ok, kept, matched_txids}` (matched in internal byte order), or
  `{:error, reason}` with the block's row marked failed. A row the lane kept
  for an older hash at this height (a reorg) is rewound first.
  """
  @spec read_block(map(), Block.t()) ::
          {:ok, non_neg_integer(), [binary()]} | {:error, term()}
  def read_block(%{lane: lane, projection: projection, slice: slice}, %Block{} = block) do
    rewind_stale(lane.projection_id, block)
    mark_reading(lane.projection_id, block, [])

    with {:ok, %{kept: kept, matched: matched, spends: spends, source: source}} <-
           read_slice(block, projection.filter, slice),
         txids = Enum.map(kept, &elem(&1, 0)),
         # Named before they are stored, so a run cut off mid-store still
         # knows what to rewind.
         :ok <- mark_reading(lane.projection_id, block, txids),
         :ok <- store(kept, block) do
      record_read(lane.projection_id, block, txids, length(matched), spends, source)

      Phoenix.PubSub.broadcast(
        Bitblocks.PubSub,
        topic(lane.projection_id),
        {:tip_lane_block,
         %{projection_id: lane.projection_id, height: block.height, hash: block.hash}}
      )

      notify_webhooks(projection, block)
      {:ok, length(kept), matched}
    else
      {:error, reason} ->
        mark_failed(lane.projection_id, block, reason)
        {:error, reason}
    end
  end

  # -- Reading a block ---------------------------------------------------------

  # The block's kept txs, `[{txid, bytes}]` in block order, once its bytes
  # passed every check. A block within the raw cap is fetched whole; a larger
  # one streams (#66) and its txs are unverified until the stream returns :ok,
  # so nothing is kept before then.
  defp read_slice(block, filter, slice) do
    whole =
      if RawBlock.eligible?(block), do: RawBlock.fetch(block), else: {:error, :block_too_large}

    acc = %{kept: [], matched: [], in_block: MapSet.new(), spends: 0}

    case whole do
      {:ok, txs, stats} ->
        acc = Enum.reduce(txs, acc, &keep(&1, &2, filter, slice, false))
        {:ok, finish(acc, to_string(stats.source))}

      {:error, :block_too_large} ->
        case BlockStream.each_tx(block, acc, &keep(&1, &2, filter, slice, true)) do
          {:ok, acc, _stats} -> {:ok, finish(acc, "rest_stream")}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(acc, source),
    do: %{
      kept: Enum.reverse(acc.kept),
      matched: acc.matched,
      spends: acc.spends,
      source: source
    }

  defp keep({txid, bytes}, acc, filter, slice, copy?) do
    cond do
      matches?(filter, bytes) ->
        id = internal(txid)

        %{
          acc
          | kept: [{txid, maybe_copy(bytes, copy?)} | acc.kept],
            matched: [id | acc.matched],
            in_block: MapSet.put(acc.in_block, id)
        }

      spends_slice?(bytes, slice, acc.in_block) ->
        %{acc | kept: [{txid, maybe_copy(bytes, copy?)} | acc.kept], spends: acc.spends + 1}

      true ->
        acc
    end
  end

  defp maybe_copy(bytes, true), do: :binary.copy(bytes)
  defp maybe_copy(bytes, false), do: bytes

  @doc """
  True when the tx `bytes` carries every tag `filter` names, by the same
  rule as the projection's query (`column @> values`): output addresses read
  from its outputs, the other columns from `TransactionParser.analyze/1`.
  """
  @spec matches?(map(), binary()) :: boolean()
  def matches?(filter, bytes) do
    {addresses, analysed} =
      Enum.split_with(filter, fn {column, _} -> column not in @analysis_columns end)

    contains_all?(addresses, fn "output_addresses" -> output_addresses(bytes) end) and
      (analysed == [] or contains_all?(analysed, analysis(bytes)))
  end

  defp contains_all?(pairs, tags) do
    Enum.all?(pairs, fn {column, values} ->
      have = tags.(column) || []
      Enum.all?(values, &(&1 in have))
    end)
  end

  defp output_addresses(bytes) do
    {_inputs, outputs} = RawBlock.tx_io(bytes)

    for({_sats, script} <- outputs, address = RawBlock.script_address(script), do: address)
    |> Enum.uniq()
  end

  defp analysis(bytes) do
    meta =
      case TransactionParser.analyze(Base.encode16(bytes, case: :lower)) do
        {:ok, meta} -> meta
        _ -> %{}
      end

    fn column -> Map.get(meta, String.to_existing_atom(column)) end
  end

  defp spends_slice?(bytes, slice, in_block) do
    if MapSet.size(slice) == 0 and MapSet.size(in_block) == 0 do
      false
    else
      {inputs, _outputs} = RawBlock.tx_io(bytes)

      Enum.any?(inputs, fn {prev, _vout, _script} ->
        MapSet.member?(slice, prev) or MapSet.member?(in_block, prev)
      end)
    end
  end

  # Display txid (hex, reversed) to the internal byte order inputs carry.
  defp internal(txid), do: txid |> Base.decode16!(case: :mixed) |> reverse()

  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  # Through the one ingest path, skipping what is stored already (and moving
  # a row left under an orphan, as the sync does: TxIngest.existing_txids/2).
  defp store(kept, block) do
    kept
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      existing = TxIngest.existing_txids(Enum.map(chunk, &elem(&1, 0)), block)

      failed =
        chunk
        |> Enum.reject(fn {txid, _} -> MapSet.member?(existing, txid) end)
        |> Enum.map(fn {txid, bytes} -> RawBlock.tx_json(txid, bytes) end)
        |> TxIngest.store_chunk(block)
        |> Enum.reject(&match?({_, :ok}, &1))

      if failed == [],
        do: {:cont, :ok},
        else: {:halt, {:error, {:unstored_txs, length(failed)}}}
    end)
  end

  # -- Reorgs ------------------------------------------------------------------

  # A row for this height under another hash: the block it read was orphaned.
  # The rows the lane kept from it, still under its hash, go (with their
  # spend edges, time locks and protocol rows); one in the new block is
  # stored again when the new block is read.
  defp rewind_stale(projection_id, %Block{} = block) do
    with %LaneBlock{block_hash: old, txids: [_ | _] = txids} = row when old != block.hash <-
           Repo.get_by(LaneBlock, projection_id: projection_id, height: block.height),
         false <- Repo.exists?(from(b in Block, where: b.hash == ^old)) do
      removed =
        txids |> Enum.chunk_every(1_000) |> Enum.map(&TxIngest.remove(&1, old)) |> Enum.sum()

      row |> Ecto.Changeset.change(txids: [], status: "reading") |> Repo.update!()

      Logger.warning(
        "tip lane ##{projection_id}: block #{block.height} was #{old}, now #{block.hash}; " <>
          "rewound #{removed} rows"
      )

      removed
    else
      _ -> 0
    end
  end

  # -- Rows --------------------------------------------------------------------

  defp mark_reading(projection_id, block, txids) do
    now = now()

    Repo.insert!(
      %LaneBlock{
        projection_id: projection_id,
        height: block.height,
        block_hash: block.hash,
        status: "reading",
        txids: txids,
        started_at: now
      },
      on_conflict: [
        set: [status: "reading", block_hash: block.hash, txids: txids, started_at: now]
      ],
      conflict_target: [:projection_id, :height]
    )

    :ok
  end

  defp record_read(projection_id, block, txids, matched, spends, source) do
    from(l in LaneBlock, where: l.projection_id == ^projection_id and l.height == ^block.height)
    |> Repo.update_all(
      set: [
        status: "read",
        block_hash: block.hash,
        txids: txids,
        matched: matched,
        spends: spends,
        source: source,
        error: nil,
        attempts: 0,
        read_at: now()
      ]
    )
  end

  defp mark_failed(projection_id, block, reason) do
    from(l in LaneBlock, where: l.projection_id == ^projection_id and l.height == ^block.height)
    |> Repo.update_all(
      set: [status: "failed", error: inspect(reason), read_at: now()],
      inc: [attempts: 1]
    )
  end

  defp notify_webhooks(projection, block) do
    Projections.notify_projection_block(projection, block)
  rescue
    e ->
      Logger.error("tip lane ##{projection.id}: webhook enqueue failed: #{Exception.message(e)}")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
