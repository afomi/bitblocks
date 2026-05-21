defmodule Bitblocks.Workers.SyncHeadersWorker do
  @moduledoc """
  Ensures block headers exist in the database.

  Two modes:

    * **Range** — fill gaps in a height range, then exit.
      `%{"mode" => "range", "from" => 0, "to" => 50_000}`

    * **Tip** — check chain tip, sync new blocks, re-enqueue in 30 s.
      `%{"mode" => "tip"}`

  For each newly inserted header, a `FetchTransactionsWorker` job is
  enqueued automatically via `Chain.queue_transaction_fetch/1`.
  """

  use Oban.Worker,
    queue: :blocks,
    max_attempts: 3,
    unique: [period: 30, fields: [:args], keys: [:mode, :from, :to]]

  require Logger

  alias Bitblocks.{Chain, Repo}
  alias Bitblocks.Chain.Block

  @batch_size 500
  @tip_delay_seconds 30

  # Max tx fetch jobs to enqueue per header batch.
  # Keeps the Oban transactions queue from flooding.
  # Remaining header_only blocks get picked up by subsequent runs.
  @max_tx_enqueue 10

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
        # Up to date — use this cycle to drain any header_only backlog
        drain_pending_tx_fetches()
        reschedule_tip(@tip_delay_seconds)
        :ok
    end
  end

  # Enqueue tx fetch for blocks stuck in header_only/header_synced.
  # Runs during idle tip cycles to steadily drain the backlog.
  defp drain_pending_tx_fetches do
    import Ecto.Query

    blocks =
      from(b in Chain.Block,
        where: b.sync_state in ["header_only", "header_synced"],
        order_by: [asc: b.height],
        limit: ^@max_tx_enqueue
      )
      |> Repo.all()

    if blocks != [] do
      Logger.info("SyncHeaders: draining #{length(blocks)} pending tx fetches")
      Enum.each(blocks, &Chain.queue_transaction_fetch/1)
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

    # Step 3: enqueue tx fetch for a limited number of newly inserted blocks.
    # The rest stay in header_only and get picked up by the next run.
    inserted
    |> Enum.take(@max_tx_enqueue)
    |> Enum.each(&Chain.queue_transaction_fetch/1)

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

      {:error, reason} ->
        Logger.error("SyncHeaders: header fetch failed for #{height}: #{inspect(reason)}")
        :error

      _ ->
        Logger.error("SyncHeaders: unexpected response for #{height}")
        :error
    end
  end
end
