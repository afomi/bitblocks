defmodule Bitblocks.Workers.CollectionTraceWorker do
  @moduledoc """
  Traces one batch of a collection's items (see `CollectionSyncWorker`).

  Checkpointed per item: an item traced at or after the run's start is
  skipped, so a batch retried after a deploy redoes nothing. An item that
  moved before trails were recorded is re-walked from its origin, so its trail
  (and so its txs in the blob store) is complete.
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

    from(i in Item, where: i.id in ^ids, order_by: i.id)
    |> Bitblocks.Repo.all()
    |> Enum.reject(&(&1.traced_at && DateTime.compare(&1.traced_at, since) != :lt))
    |> Enum.each(fn item ->
      opts =
        if item.trail == [] and item.current_outpoint != item.origin,
          do: [from: :origin],
          else: []

      {:ok, _} = OrdinalCollections.trace(item, opts)
    end)

    if last_batch?(job_id, slug, started), do: log_done(slug)
    :ok
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
