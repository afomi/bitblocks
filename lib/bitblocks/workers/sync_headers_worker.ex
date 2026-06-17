defmodule Bitblocks.Workers.SyncHeadersWorker do
  @moduledoc """
  Ensures block headers exist in the database.

  Two modes:

    * **Range** — fill header gaps in a height range, then exit. Headers only;
      transaction fetching is driven separately in metered waves by the backfill
      (see `docs/SYNCING.md`).
      `%{"mode" => "range", "from" => 0, "to" => 50_000}`

    * **Tip** — check chain tip, sync new headers, AND enqueue a transaction
      fetch for each new block (via `Chain.queue_transaction_fetch/1`) so the
      chain stays fully synced hands-off. Re-enqueues itself in 30 s.
      `%{"mode" => "tip"}`
  """

  use Oban.Worker,
    queue: :blocks,
    max_attempts: 3,
    unique: [period: 30, fields: [:args], keys: [:mode, :from, :to]]

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Bitblocks.{Chain, Repo}
  alias Bitblocks.Chain.Block
  alias Bitblocks.Chain.HeaderVerifier

  @batch_size 500
  @tip_delay_seconds 30

  # -- perform -----------------------------------------------------------------

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "range", "from" => from, "to" => to}}) do
    sync_range(from, to)
  end

  def perform(%Oban.Job{args: %{"mode" => "tip"}}) do
    sync_tip()
  end

  # -- range mode --------------------------------------------------------------

  # `enqueue_txs?` controls whether newly-stored headers also get a transaction
  # fetch queued. Tip mode passes `true` so the chain stays fully synced
  # hands-off; range/backfill mode passes `false` because a bulk backfill drives
  # transaction fetching separately in metered waves (see docs/SYNCING.md) —
  # auto-enqueuing there would flood the oban_jobs table.
  defp sync_range(from, to, enqueue_txs? \\ false) do
    gaps = Chain.missing_block_ranges(from, to)

    total_missing =
      Enum.reduce(gaps, 0, fn {s, e}, acc -> acc + (e - s + 1) end)

    if total_missing == 0 do
      Logger.info("SyncHeaders: range #{from}..#{to} — no gaps")
      :ok
    else
      Logger.info(
        "SyncHeaders: #{total_missing} missing blocks in #{length(gaps)} gap(s) (#{from}..#{to})"
      )

      Enum.each(gaps, &process_gap(&1, enqueue_txs?))
      :ok
    end
  end

  defp process_gap({gap_start, gap_end}, enqueue_txs?) do
    gap_start
    |> Stream.iterate(&(&1 + @batch_size))
    |> Stream.take_while(&(&1 <= gap_end))
    |> Enum.each(fn batch_start ->
      batch_end = min(batch_start + @batch_size - 1, gap_end)
      fetch_and_store_headers(batch_start, batch_end, enqueue_txs?)
    end)
  end

  # -- tip mode ----------------------------------------------------------------

  defp sync_tip do
    chain_tip = get_chain_tip()
    our_tip = get_our_tip()

    cond do
      chain_tip == nil ->
        Logger.warning("SyncHeaders: cannot reach node, retrying in 60s")
        reschedule_tip(60)
        :ok

      chain_tip > our_tip ->
        new_count = chain_tip - our_tip
        Logger.info("SyncHeaders: tip #{new_count} new blocks (#{our_tip + 1}..#{chain_tip})")
        # Tip mode enqueues tx fetches for the new blocks so the chain stays
        # fully synced with no manual intervention (volume is bounded — a few
        # blocks per cycle).
        case sync_range_tip(our_tip + 1, chain_tip) do
          {:reorg, fork_height, node_hash} ->
            handle_reorg(fork_height, node_hash)

          _ ->
            :ok
        end

        reschedule_tip(@tip_delay_seconds)
        :ok

      true ->
        # Up to date — nothing new to fetch.
        reschedule_tip(@tip_delay_seconds)
        :ok
    end
  end

  # Tip-mode range sync — propagates {:reorg, height, hash} up if detected.
  defp sync_range_tip(from, to) do
    gaps = Chain.missing_block_ranges(from, to)

    Enum.reduce_while(gaps, :ok, fn {gap_start, gap_end}, _acc ->
      case fetch_and_store_headers_tip(gap_start, gap_end) do
        {:reorg, _, _} = reorg -> {:halt, reorg}
        _ -> {:cont, :ok}
      end
    end)
  end

  # Walk back from fork_height to find where our chain and the node's chain
  # diverge, delete our orphaned blocks, and re-fetch from the fork point.
  # Capped at @max_reorg_depth to avoid runaway deletes on a misconfigured node.
  @max_reorg_depth 10

  defp handle_reorg(fork_height, node_hash) do
    Logger.warning("SyncHeaders: reorg detected at height #{fork_height} — resolving")

    case find_fork_point(fork_height, node_hash, 0) do
      {:ok, fork_point} ->
        orphan_heights = (fork_point + 1)..fork_height |> Enum.to_list()

        Logger.warning(
          "SyncHeaders: reorg fork point #{fork_point}, deleting orphans #{fork_point + 1}..#{fork_height}"
        )

        Enum.each(orphan_heights, fn h ->
          case Chain.get_block(h) do
            nil -> :ok
            block -> Chain.delete_block(block)
          end
        end)

        Logger.warning("SyncHeaders: reorg resolved, re-syncing from #{fork_point + 1}")
        fetch_and_store_headers(fork_point + 1, fork_height, true)

      {:error, :too_deep} ->
        Logger.error(
          "SyncHeaders: reorg exceeds #{@max_reorg_depth} blocks deep — manual intervention required"
        )
    end
  end

  # Walk back from `height` following the node's chain via previousblockhash
  # until we find a height where our stored hash matches the node's prevhash
  # (meaning the node and our DB agree on that ancestor).
  defp find_fork_point(_height, _node_hash, depth) when depth > @max_reorg_depth,
    do: {:error, :too_deep}

  defp find_fork_point(height, node_hash, depth) do
    case BitcoinsvCli.getblockheader(node_hash, true) do
      %{"previousblockhash" => prev_hash, "height" => ^height} ->
        prev_height = height - 1

        case Chain.get_block(prev_height) do
          %Block{hash: ^prev_hash} ->
            # Our block at prev_height matches the node's prevhash — fork point found.
            {:ok, prev_height}

          %Block{} ->
            # Mismatch — keep walking back.
            find_fork_point(prev_height, prev_hash, depth + 1)

          nil ->
            # We don't have the predecessor at all — treat this height as the fork point.
            {:ok, prev_height}
        end

      _ ->
        {:error, :too_deep}
    end
  end

  defp reschedule_tip(delay) do
    %{"mode" => "tip"}
    |> __MODULE__.new(schedule_in: delay)
    |> Oban.insert()
  end

  defp get_chain_tip do
    case Bitblocks.RpcCache.get_blockchain_info() do
      %{"blocks" => tip} when is_integer(tip) -> tip
      _ -> nil
    end
  end

  defp get_our_tip do
    case Chain.get_latest_block() do
      nil -> -1
      block -> block.height
    end
  end

  # -- header fetch + store ----------------------------------------------------

  defp fetch_and_store_headers(from, to, enqueue_txs?) do
    {inserted, _} = do_fetch_and_store_headers(from, to, enqueue_txs?, _stop_on_reorg = false)

    if inserted != [] do
      Logger.info("SyncHeaders: stored #{length(inserted)} headers (#{from}..#{to})")
      if enqueue_txs?, do: Enum.each(inserted, &Chain.queue_transaction_fetch/1)
    end
  end

  # Tip variant — halts on first reorg signal and returns it so the caller can resolve.
  defp fetch_and_store_headers_tip(from, to) do
    case do_fetch_and_store_headers(from, to, true, _stop_on_reorg = true) do
      {inserted, {:reorg, _, _} = reorg} ->
        if inserted != [],
          do: Logger.info("SyncHeaders: stored #{length(inserted)} headers (#{from}..#{to})")

        reorg

      {inserted, _} ->
        if inserted != [] do
          Logger.info("SyncHeaders: stored #{length(inserted)} headers (#{from}..#{to})")
          Enum.each(inserted, &Chain.queue_transaction_fetch/1)
        end

        :ok
    end
  end

  defp do_fetch_and_store_headers(from, to, _enqueue_txs?, stop_on_reorg) do
    heights = Enum.to_list(from..to)
    hashes = fetch_hashes(heights)

    Enum.reduce_while(heights, {[], :ok}, fn height, {acc, _} ->
      case Map.get(hashes, height) do
        hash when is_binary(hash) ->
          case insert_header(height, hash) do
            {:ok, block} ->
              {:cont, {[block | acc], :ok}}

            {:reorg, _, _} = reorg when stop_on_reorg ->
              {:halt, {Enum.reverse(acc), reorg}}

            _ ->
              {:cont, {acc, :ok}}
          end

        _ ->
          {:cont, {acc, :ok}}
      end
    end)
    |> then(fn {acc, signal} -> {Enum.reverse(acc), signal} end)
  end

  defp fetch_hashes(heights) do
    case BitcoinsvCli.batch_getblockhash(heights) do
      {:ok, hash_map} ->
        hash_map

      {:error, reason} ->
        Logger.warning("SyncHeaders: batch hash fetch failed (#{inspect(reason)}), falling back")

        Map.new(heights, fn h ->
          case BitcoinsvCli.getblockhash(h) do
            hash when is_binary(hash) -> {h, hash}
            _ -> {h, nil}
          end
        end)
    end
  end

  defp insert_header(height, hash) do
    case BitcoinsvCli.getblockheader(hash, true) do
      %{"hash" => ^hash} = header ->
        # TB2: the node is not unconditionally trusted. Confirm the header
        # actually hashes to the hash we asked for (and meets PoW) before
        # persisting it, then check it chains onto the predecessor we already
        # hold — so a rogue/buggy node can't poison the index with a relabelled,
        # trivially-mined, or off-chain header (threat T4).
        with :ok <- HeaderVerifier.verify(header, hash),
             :ok <- check_continuity(height, header) do
          store_verified_header(height, hash, header)
        else
          {:error, :prevhash_mismatch} -> {:reorg, height, hash}
          {:error, reason} -> reject_header(height, hash, reason)
        end

      {:error, reason} ->
        Logger.error("SyncHeaders: header fetch failed for #{height}: #{inspect(reason)}")
        :error

      _ ->
        Logger.error("SyncHeaders: unexpected response for #{height}")
        :error
    end
  end

  # T4 (continuity): if we already hold the block at height-1, this header's
  # previousblockhash must equal that block's hash — otherwise the node is
  # serving an off-chain/orphan header for this height. When the predecessor
  # isn't present yet (gap-filling out of order), we can't check and allow it;
  # genesis (height 0) has no predecessor.
  defp check_continuity(0, _header), do: :ok

  defp check_continuity(height, header) do
    predecessor = Repo.one(from b in Block, where: b.height == ^(height - 1), limit: 1)
    continuity(predecessor, header)
  end

  @doc false
  # Pure continuity check, separated for testing. `predecessor` is the block we
  # already hold at height-1 (or nil if absent).
  def continuity(nil, _header), do: :ok

  def continuity(%Block{hash: prev_hash}, header) do
    node_prevhash = Map.get(header, "previousblockhash")

    if normalize_hash(node_prevhash) == normalize_hash(prev_hash) do
      :ok
    else
      Logger.error(
        "SyncHeaders: continuity mismatch — stored=#{inspect(prev_hash)} node_prevhash=#{inspect(node_prevhash)}"
      )

      {:error, :prevhash_mismatch}
    end
  end

  defp normalize_hash(nil), do: nil
  defp normalize_hash(hash), do: hash |> String.trim() |> String.downcase()

  defp reject_header(height, hash, reason) do
    Logger.error(
      "SyncHeaders: REJECTED header for #{height} (#{hash}) — failed verification: #{inspect(reason)}"
    )

    :error
  end

  defp store_verified_header(height, hash, header) do
    block_attrs = %Block{
      hash: hash,
      height: height,
      num_tx: Map.get(header, "num_tx", 0),
      time: header["time"],
      bits: header["bits"],
      chainwork: Map.get(header, "chainwork", ""),
      difficulty: to_string(Map.get(header, "difficulty", "")),
      mediantime: Map.get(header, "mediantime", header["time"]),
      merkleroot: header["merkleroot"],
      prevblockhash: Map.get(header, "previousblockhash", ""),
      nextblockhash: Map.get(header, "nextblockhash", ""),
      nonce: header["nonce"],
      version: header["version"],
      tx: [],
      sync_state: "header_only"
    }

    case Repo.insert(Ecto.Changeset.change(block_attrs, %{}), on_conflict: :nothing) do
      {:ok, %{id: nil}} ->
        # Conflict — block already existed
        :exists

      {:ok, block} ->
        {:ok, block}

      {:error, changeset} ->
        Logger.error("SyncHeaders: insert failed for #{height}: #{inspect(changeset.errors)}")
        :error
    end
  end
end
