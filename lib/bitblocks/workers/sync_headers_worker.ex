defmodule Bitblocks.Workers.SyncHeadersWorker do
  @moduledoc """
  Ensures block headers exist in the database.

  Headers only: transactions are the sync loop's job (`SyncWorker`, see
  docs/SYNCING.md), which reaches every stored header in ascending order.

    * **Range** — fill header gaps in a height range, then exit.
      `%{"mode" => "range", "from" => 0, "to" => 50_000}`

    * **Tip** — store new headers up to the node's tip and resolve a reorg.
      `SyncWorker` calls `sync_tip/0` every minute; a tip job does the same once.
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

  # Headers per batch (one batch_getblockhash + one batch_getblockheader). A
  # public endpoint (PublicNode) rate limits bursts, so the size and the pause
  # before each batch are runtime config (HEADER_BATCH_SIZE,
  # HEADER_BATCH_PAUSE_MS); BitcoinsvCli backs off and retries on a 429 too.
  defp batch_size, do: Application.get_env(:bitblocks, :header_batch_size, 500)

  # -- perform -----------------------------------------------------------------

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "range", "from" => from, "to" => to}}) do
    sync_range(from, to)
  end

  def perform(%Oban.Job{args: %{"mode" => "tip"}}) do
    sync_tip()
  end

  # -- range mode --------------------------------------------------------------

  @doc "Stores the headers missing between heights `from` and `to`."
  def sync_range(from, to) do
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

      Enum.each(gaps, &process_gap/1)
      :ok
    end
  end

  defp process_gap({gap_start, gap_end}) do
    gap_start
    |> Stream.iterate(&(&1 + batch_size()))
    |> Stream.take_while(&(&1 <= gap_end))
    |> Enum.each(fn batch_start ->
      batch_end = min(batch_start + batch_size() - 1, gap_end)
      fetch_and_store_headers(batch_start, batch_end)
    end)
  end

  # -- tip mode ----------------------------------------------------------------

  @doc """
  Stores new headers up to the node's tip, resolving a reorg if one is found.
  Returns `{:error, :node_unreachable}` when the node's tip is unknown.

  When the node isn't ahead of us, its best block hash is compared with the
  block we store at its height (#34): a same-height replacement or a rollback
  to a heavier, shorter chain is a reorg with no new block to reveal it.
  `info` is the node's `getblockchaininfo` answer.
  """
  def sync_tip(info \\ Bitblocks.RpcCache.get_blockchain_info()) do
    chain_tip = get_chain_tip(info)
    our_tip = get_our_tip()

    cond do
      chain_tip == nil ->
        Logger.warning("SyncHeaders: cannot reach node; the next run tries again")
        {:error, :node_unreachable}

      chain_tip > our_tip ->
        Logger.info(
          "SyncHeaders: tip #{chain_tip - our_tip} new blocks (#{our_tip + 1}..#{chain_tip})"
        )

        case sync_range_tip(our_tip + 1, chain_tip) do
          {:reorg, fork_height, node_hash} -> handle_reorg(fork_height, node_hash)
          _ -> :ok
        end

        :ok

      true ->
        check_best_hash(info, chain_tip, our_tip)
    end
  end

  defp check_best_hash(%{"bestblockhash" => best}, chain_tip, our_tip) when is_binary(best) do
    case Chain.get_block_at_height(chain_tip) do
      %Block{hash: ^best} ->
        :ok

      %Block{} ->
        # The cache can be minutes old, so a difference is only a question:
        # the node's live answer decides, and the cached one is dropped.
        Bitblocks.RpcCache.invalidate_blockchain_info()
        resolve_best_hash(rpc().getblockchaininfo(), our_tip)

      nil ->
        :ok
    end
  end

  defp check_best_hash(_info, _chain_tip, _our_tip), do: :ok

  defp resolve_best_hash(%{"blocks" => tip, "bestblockhash" => best}, our_tip)
       when is_integer(tip) and is_binary(best) and tip <= our_tip do
    with %Block{hash: stored} when stored != best <- Chain.get_block_at_height(tip) do
      if outweighs_our_tip?(best, tip, our_tip) do
        handle_reorg(tip, best, our_tip)
      else
        Logger.warning(
          "SyncHeaders: node tip #{tip} (#{best}) is on a lighter branch than ours; waiting"
        )
      end
    end

    :ok
  end

  # The node moved on, or didn't answer: the next run looks again.
  defp resolve_best_hash(_info, _our_tip), do: :ok

  # A node that is merely behind, or on a stale branch, must never rewind us.
  # Equal work at equal height follows the node; a lower tip needs proof it
  # carries at least our work.
  defp outweighs_our_tip?(best, tip, our_tip) do
    theirs =
      case rpc().getblockheader(best, true) do
        %{"chainwork" => work} -> chainwork(work)
        _ -> nil
      end

    ours =
      case Chain.get_block_at_height(our_tip) do
        %Block{chainwork: work} -> chainwork(work)
        nil -> nil
      end

    if is_integer(theirs) and is_integer(ours), do: theirs >= ours, else: tip == our_tip
  end

  defp chainwork(hex) when is_binary(hex) do
    case Integer.parse(hex, 16) do
      {work, ""} -> work
      _ -> nil
    end
  end

  defp chainwork(_hex), do: nil

  # Tip-mode range sync — propagates {:reorg, height, hash} up if detected.
  # Walked in batch_size() chunks, like range mode, so a catch-up after an
  # outage never sends one huge batch_getblockhash.
  defp sync_range_tip(from, to) do
    gaps = Chain.missing_block_ranges(from, to)

    size = batch_size()

    chunks =
      for {gap_start, gap_end} <- gaps,
          batch_start <- gap_start..gap_end//size,
          do: {batch_start, min(batch_start + size - 1, gap_end)}

    Enum.reduce_while(chunks, :ok, fn {chunk_start, chunk_end}, _acc ->
      case fetch_and_store_headers_tip(chunk_start, chunk_end) do
        {:reorg, _, _} = reorg -> {:halt, reorg}
        _ -> {:cont, :ok}
      end
    end)
  end

  # Walk back from fork_height to find where our chain and the node's chain
  # diverge, delete our orphaned blocks, and re-fetch from the fork point.
  # Capped at @max_reorg_depth to avoid runaway deletes on a misconfigured node.
  @max_reorg_depth 10

  defp handle_reorg(fork_height, node_hash, top \\ nil) do
    Logger.warning("SyncHeaders: reorg detected at height #{fork_height} — resolving")

    case fork_point(fork_height, node_hash) do
      {:ok, fork_point} ->
        Logger.warning(
          "SyncHeaders: reorg fork point #{fork_point}, deleting orphans #{fork_point + 1}..#{fork_height}"
        )

        # `top`: our own tip, when it stands above the node's.
        orphans = delete_orphans(fork_point, max(fork_height, top || fork_height))
        orphan_count = length(orphans)

        Logger.warning("SyncHeaders: reorg resolved, re-syncing from #{fork_point + 1}")

        if record_reorg(fork_height, fork_point, orphan_count) == :first_report do
          Bitblocks.Notifications.reorg_alert(fork_height, fork_point, orphan_count)
        end

        notify_projections_of_reorg(fork_point)

        Chain.broadcast_reorg(%{
          fork_point: fork_point,
          fork_height: fork_height,
          orphans: Enum.map(orphans, & &1.hash)
        })

        fetch_and_store_headers(fork_point + 1, fork_height)
        enqueue_reconcile(orphans)

      {:error, {:rpc, reason}} ->
        # The node didn't answer the walk (busy verifying, timeout, 403). That
        # says nothing about the fork's depth: record nothing, send no alert,
        # and let the next tip run detect and resolve it again.
        Logger.warning(
          "SyncHeaders: reorg at #{fork_height} unresolved, node call failed (#{inspect(reason)}); retrying next run"
        )

      {:error, :too_deep} ->
        Logger.error(
          "SyncHeaders: reorg exceeds #{@max_reorg_depth} blocks deep — manual intervention required"
        )

        # Tip sync meets this fork every minute until an operator steps in:
        # the reorg row refreshes each time, and one email goes out for it.
        if record_reorg(fork_height, nil, nil) == :first_report do
          Bitblocks.Notifications.reorg_alert(fork_height, nil, nil)
        end
    end
  end

  # Phase 1 of #34: an annotation and a notice for admins. Transaction rows are
  # reconciled afterwards by ReconcileOrphanWorker. Returns :first_report for
  # a new row, :repeat for the same fork seen again, so a repeat sends no
  # email. A row that couldn't be written still counts as a first report.
  defp record_reorg(fork_height, fork_point, orphan_count) do
    outcome = if is_integer(fork_point), do: "resolved", else: "needs_attention"

    case Bitblocks.Reorgs.record_observed(%{
           fork_height: fork_height,
           fork_point: fork_point,
           orphan_count: orphan_count,
           outcome: outcome
         }) do
      {:ok, reorg} ->
        if Bitblocks.Reorgs.repeat_report?(reorg), do: :repeat, else: :first_report

      {:error, changeset} ->
        Logger.error("SyncHeaders: reorg record failed: #{inspect(changeset.errors)}")
        :first_report
    end
  rescue
    exception ->
      Logger.error("SyncHeaders: reorg record failed: #{Exception.message(exception)}")
      :first_report
  end

  # Webhook projections drop rows above the fork point (#29 step 4). Never
  # interrupts reorg resolution.
  defp notify_projections_of_reorg(fork_point) do
    Bitblocks.Projections.notify_reorg(fork_point)
  rescue
    e -> Logger.error("SyncHeaders: projection reorg notify failed: #{Exception.message(e)}")
  end

  # Walk back from `height` following the node's chain via previousblockhash
  # until we find a height where our stored hash matches the node's prevhash
  # (meaning the node and our DB agree on that ancestor).
  @doc false
  def fork_point(height, node_hash), do: find_fork_point(height, node_hash, 0)

  # Deletes our blocks above the fork point, by height. Returns the deleted
  # blocks: their count is the reorg's orphan count. Heights we never stored
  # (the node's new blocks above our old tip) aren't orphans.
  @doc false
  def delete_orphans(fork_point, fork_height) do
    Enum.flat_map((fork_point + 1)..fork_height//1, fn h ->
      with %Block{} = block <- Chain.get_block_at_height(h),
           {:ok, _} <- Chain.delete_block(block) do
        [block]
      else
        _ -> []
      end
    end)
  end

  # Each orphan's transaction rows still carry its hash. A job per orphan
  # moves them to the blocks that hold them now, or removes them (#34).
  # Never interrupts reorg resolution.
  @doc false
  def enqueue_reconcile(orphans) do
    for %Block{hash: hash} <- orphans do
      hash |> Bitblocks.Workers.ReconcileOrphanWorker.job() |> Oban.insert()
    end

    :ok
  rescue
    e -> Logger.error("SyncHeaders: reconcile enqueue failed: #{Exception.message(e)}")
  end

  defp find_fork_point(_height, _node_hash, depth) when depth > @max_reorg_depth,
    do: {:error, :too_deep}

  defp find_fork_point(height, node_hash, depth) do
    case rpc().getblockheader(node_hash, true) do
      %{"previousblockhash" => prev_hash, "height" => ^height} ->
        prev_height = height - 1

        case Chain.get_block_at_height(prev_height) do
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

      {:error, reason} ->
        {:error, {:rpc, reason}}

      other ->
        # A header for a different height, or no previousblockhash: the node
        # isn't describing the chain we're walking.
        {:error, {:rpc, {:unexpected_header, other}}}
    end
  end

  defp get_chain_tip(%{"blocks" => tip}) when is_integer(tip), do: tip
  defp get_chain_tip(_info), do: nil

  defp get_our_tip do
    case Chain.get_latest_block() do
      nil -> -1
      block -> block.height
    end
  end

  # -- header fetch + store ----------------------------------------------------

  defp fetch_and_store_headers(from, to) do
    {inserted, _} = do_fetch_and_store_headers(from, to, _stop_on_reorg = false)
    log_stored(inserted, from, to)
  end

  # Tip variant — halts on first reorg signal and returns it so the caller can resolve.
  defp fetch_and_store_headers_tip(from, to) do
    {inserted, signal} = do_fetch_and_store_headers(from, to, _stop_on_reorg = true)
    log_stored(inserted, from, to)
    signal
  end

  defp log_stored([], _from, _to), do: :ok

  defp log_stored(inserted, from, to),
    do: Logger.info("SyncHeaders: stored #{length(inserted)} headers (#{from}..#{to})")

  defp do_fetch_and_store_headers(from, to, stop_on_reorg) do
    pause_ms = Application.get_env(:bitblocks, :header_batch_pause_ms, 0)
    if pause_ms > 0, do: Process.sleep(pause_ms)
    heights = Enum.to_list(from..to)
    hashes = fetch_hashes(heights)
    headers = prefetch_headers(hashes)

    Enum.reduce_while(heights, {[], :ok}, fn height, {acc, _} ->
      case Map.get(hashes, height) do
        hash when is_binary(hash) ->
          case insert_header(height, hash, Map.get(headers, hash)) do
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
    case rpc().batch_getblockhash(heights) do
      {:ok, hash_map} ->
        hash_map

      {:error, reason} ->
        Logger.warning("SyncHeaders: batch hash fetch failed (#{inspect(reason)}), falling back")

        Map.new(heights, fn h ->
          case rpc().getblockhash(h) do
            hash when is_binary(hash) -> {h, hash}
            _ -> {h, nil}
          end
        end)
    end
  end

  # One batch request for the whole chunk's headers. Anything the batch
  # didn't return is fetched singly in insert_header/3.
  defp prefetch_headers(hashes) do
    case hashes |> Map.values() |> Enum.filter(&is_binary/1) do
      [] ->
        %{}

      list ->
        case rpc().batch_getblockheader(list) do
          {:ok, results} -> for {hash, %{} = header} <- results, into: %{}, do: {hash, header}
          {:error, _} -> %{}
        end
    end
  end

  defp insert_header(height, hash, prefetched) do
    case prefetched || rpc().getblockheader(hash, true) do
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
        Chain.broadcast_block_update(block)
        {:ok, block}

      {:error, changeset} ->
        Logger.error("SyncHeaders: insert failed for #{height}: #{inspect(changeset.errors)}")
        :error
    end
  end

  # Swappable RPC client — tests point this at BitcoinsvCliMock (config/test.exs).
  defp rpc, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
end
