defmodule Bitblocks.Workers.SyncHeadersWorker do
  @moduledoc """
  Ensures block headers exist in the database. Headers only — no
  transaction fetching. Transaction downloads are handled separately
  by `BackfillTransactionsWorker` (sequential, one block at a time).

  Two modes:

    * **Range** — fill gaps in a height range, then exit.
      `%{"mode" => "range", "from" => 0, "to" => 50_000}`

    * **Tip** — check chain tip, sync new headers, re-enqueue in 30 s.
      `%{"mode" => "tip"}`
  """

  use Oban.Worker,
    queue: :blocks,
    max_attempts: 3,
    unique: [period: 30, fields: [:args], keys: [:mode, :from, :to]]

  require Logger

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

  defp sync_range(from, to) do
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
    |> Stream.iterate(&(&1 + @batch_size))
    |> Stream.take_while(&(&1 <= gap_end))
    |> Enum.each(fn batch_start ->
      batch_end = min(batch_start + @batch_size - 1, gap_end)
      fetch_and_store_headers(batch_start, batch_end)
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
        sync_range(our_tip + 1, chain_tip)
        reschedule_tip(@tip_delay_seconds)
        :ok

      true ->
        # Up to date — headers only. Transaction fetching is handled
        # by BackfillTransactionsWorker (sequential, one block at a time).
        reschedule_tip(@tip_delay_seconds)
        :ok
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

  defp fetch_and_store_headers(from, to) do
    heights = Enum.to_list(from..to)

    # Step 1: batch-fetch hashes (falls back to individual calls)
    hashes = fetch_hashes(heights)

    # Step 2: for each hash, fetch header and insert
    inserted =
      heights
      |> Enum.flat_map(fn height ->
        case Map.get(hashes, height) do
          hash when is_binary(hash) ->
            case insert_header(height, hash) do
              {:ok, block} -> [block]
              _ -> []
            end

          _ ->
            []
        end
      end)

    if inserted != [] do
      Logger.info("SyncHeaders: stored #{length(inserted)} headers (#{from}..#{to})")
    end
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
  defp check_continuity(height, header), do: continuity(Chain.get_block(height - 1), header)

  @doc false
  # Pure continuity check, separated for testing. `predecessor` is the block we
  # already hold at height-1 (or nil if absent).
  def continuity(nil, _header), do: :ok

  def continuity(%Block{hash: prev_hash}, header) do
    if Map.get(header, "previousblockhash") == prev_hash do
      :ok
    else
      {:error, :prevhash_mismatch}
    end
  end

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
