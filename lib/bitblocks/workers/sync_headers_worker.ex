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

  # How many blocks to process for tx fetch per drain cycle.
  @drain_batch 20

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
      # No gaps in headers — drain any pending tx fetches
      drain_pending_tx_fetches()
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

  # Fetch transactions inline for blocks in header_only/header_synced.
  # Tight loop: upgrade block → fetch txs → store → next. No Oban per-block overhead.
  defp drain_pending_tx_fetches do
    import Ecto.Query

    blocks =
      from(b in Block,
        where: b.sync_state in ["header_only", "header_synced"],
        order_by: [asc: b.height],
        limit: ^@drain_batch
      )
      |> Repo.all()

    if blocks != [] do
      Logger.info("SyncHeaders: fetching txs for #{length(blocks)} blocks inline")

      completed =
        Enum.count(blocks, fn block ->
          case sync_block_transactions(block) do
            :ok -> true
            _ -> false
          end
        end)

      Logger.info("SyncHeaders: completed #{completed}/#{length(blocks)} blocks")
    end
  end

  # Fetch all transactions for a single block. Inline, no Oban job.
  # 1. Upgrade to get txid list (if needed)
  # 2. Skip txids already in DB
  # 3. Fetch remaining txs from RPC
  # 4. Store and mark block completed
  defp sync_block_transactions(%Block{} = block) do
    with {:ok, block} <- ensure_txids(block),
         {:ok, block} <- mark_syncing(block) do
      txids = block.tx || []
      existing = existing_txids_for_block(block.hash)
      missing = txids -- existing

      if missing == [] do
        mark_completed(block)
        :ok
      else
        case fetch_and_store_txs(missing, block) do
          :ok ->
            mark_completed(block)
            :ok

          {:error, reason} ->
            mark_failed(block, reason)
            {:error, reason}
        end
      end
    else
      {:error, reason} ->
        Logger.error("SyncHeaders: tx sync failed for block #{block.height}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_txids(%Block{tx: tx} = block) when is_list(tx) and tx != [] do
    {:ok, block}
  end

  defp ensure_txids(%Block{hash: hash}) do
    case Chain.upgrade_block_to_header_synced(hash) do
      {:ok, upgraded} -> {:ok, upgraded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_txids_for_block(block_hash) do
    import Ecto.Query

    from(t in Chain.Transaction,
      where: t.block_hash == ^block_hash,
      select: t.txid
    )
    |> Repo.all()
  end

  defp fetch_and_store_txs(txids, block) do
    alias Bitblocks.TransactionParser

    errors =
      Enum.filter(txids, fn txid ->
        case BitcoinsvCli.getrawtransaction(txid, 1) do
          tx when is_map(tx) ->
            raw = tx["hex"]

            analysis =
              case TransactionParser.analyze(raw) do
                {:ok, meta} -> meta
                _ -> %{}
              end

            inputs = (tx["vin"] || []) |> Enum.map(&Jason.encode!/1)
            outputs = (tx["vout"] || []) |> Enum.map(&Jason.encode!/1)

            tx_data =
              Map.merge(
                %{
                  txid: tx["txid"],
                  raw: raw,
                  block_hash: tx["blockhash"] || block.hash,
                  block_height: tx["height"] || block.height,
                  version: to_string(tx["version"] || 1),
                  inputs: inputs,
                  input_txids: TransactionParser.extract_input_txids(inputs),
                  outputs: outputs,
                  output_addresses: TransactionParser.extract_output_addresses(outputs)
                },
                analysis
              )

            changeset = Chain.Transaction.changeset(%Chain.Transaction{}, tx_data)

            case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :txid) do
              {:ok, stored_tx} -> Chain.record_spends(stored_tx)
              _ -> :ok
            end

            false

          error ->
            Logger.warning("SyncHeaders: failed to fetch tx #{txid}: #{inspect(error)}")
            true
        end
      end)

    if errors == [], do: :ok, else: {:error, "#{length(errors)} tx(s) failed"}
  end

  defp mark_syncing(block) do
    block
    |> Ecto.Changeset.change(%{
      sync_state: "txs_syncing",
      tx_sync_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> tap(fn {:ok, b} -> Chain.broadcast_block_update(b); _ -> :ok end)
  end

  defp mark_completed(block) do
    block
    |> Ecto.Changeset.change(%{
      sync_state: "completed",
      tx_sync_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> tap(fn {:ok, b} -> Chain.broadcast_block_update(b); _ -> :ok end)
  end

  defp mark_failed(block, error) do
    block
    |> Ecto.Changeset.change(%{
      sync_state: "failed",
      tx_sync_error: inspect(error)
    })
    |> Repo.update()
    |> tap(fn {:ok, b} -> Chain.broadcast_block_update(b); _ -> :ok end)
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
