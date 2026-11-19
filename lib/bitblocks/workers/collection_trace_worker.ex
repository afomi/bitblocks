defmodule Bitblocks.Workers.CollectionTraceWorker do
  @moduledoc """
  Traces one batch of a collection's items (see `CollectionSyncWorker`).

  Checkpointed per item: an item traced at or after the run's start is
  skipped, so a batch retried after a deploy redoes nothing. An item that
  moved before trails were recorded is re-walked from its origin, so its trail
  (and so its txs in the blob store) is complete.

  The batch is traced together, hop by hop, from our own index
  (`OrdinalCollections.trace_batch/1`): WhatsOnChain is asked only for the
  raw bytes of txs we lack, in bulk. Each batch logs its spend lookups, tx
  reads, raw-tx fetches and elapsed time. Job args are unchanged, so a job
  enqueued by older code runs as it is.
  """
  use Oban.Worker,
    queue: :collections,
    max_attempts: 10,
    unique: [period: :infinity, keys: [:slug, :ids, :run_started_at]]

  require Logger

  import Ecto.Query

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.Item

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        args: %{"slug" => slug, "ids" => ids, "run_started_at" => started}
      }) do
    {:ok, since, _} = DateTime.from_iso8601(started)
    began = System.monotonic_time(:millisecond)

    {stats, peak} =
      OrdinalCollections.measure(fn ->
        from(i in Item, where: i.id in ^ids, order_by: i.id)
        |> Bitblocks.Repo.all()
        |> Enum.reject(&(&1.traced_at && DateTime.compare(&1.traced_at, since) != :lt))
        |> Enum.map(fn item ->
          opts =
            if item.trail == [] and item.current_outpoint != item.origin,
              do: [from: :origin],
              else: []

          {item, opts}
        end)
        |> trace()
      end)

    log_batch(slug, stats, System.monotonic_time(:millisecond) - began)

    if cid = OrdinalCollections.resolve(slug), do: OrdinalCollections.record_trace_peak(cid, peak)

    if last_batch?(job_id, slug, started), do: log_done(slug)
    :ok
  end

  # The whole batch at once, hop by hop (`OrdinalCollections.trace_batch/1`).
  defp trace([]), do: nil

  defp trace(entries) do
    # An item a reorg removed while it was traced comes back as :gone.
    {:ok, _items_or_gone, stats} = OrdinalCollections.trace_batch(entries)
    stats
  end

  # Where the batch's time went: local lookups against raw-tx fetches.
  defp log_batch(slug, nil, ms),
    do: Logger.info("collection trace #{slug}: nothing left in this batch (#{ms} ms)")

  defp log_batch(slug, stats, ms) do
    Logger.info(
      "collection trace #{slug}: #{stats.items} items, #{stats.hops} hops, " <>
        "#{stats.spend_lookups} spend lookups and #{stats.tx_reads} tx reads from our index, " <>
        "#{stats.raw_txs_fetched} raw txs fetched in #{stats.woc_requests} WhatsOnChain " <>
        "requests, #{ms} ms"
    )
  end

  # This run's other trace batches: none left pending means this was the last.
  defp last_batch?(job_id, slug, started) do
    others =
      from j in Oban.Job,
        where:
          j.worker == "Bitblocks.Workers.CollectionTraceWorker" and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("?->>'slug' = ?", j.args, ^slug) and
            fragment("?->>'run_started_at' = ?", j.args, ^started)

    # This job is still executing; don't count it.
    others = if job_id, do: where(others, [j], j.id != ^job_id), else: others
    not Bitblocks.Repo.exists?(others)
  end

  defp log_done(slug) do
    cid = OrdinalCollections.resolve(slug)

    Logger.info(
      "sync_ordinal_collection #{slug}: done #{inspect(OrdinalCollections.summary(cid))}"
    )
  end
end
