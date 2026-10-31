defmodule Bitblocks.Workers.CollectionSyncWorker do
  @moduledoc """
  Syncs a collection as Oban jobs, so a deploy no longer kills it (infra,
  2026-10-30). This job imports the mints and walks the chain (idempotent: a
  rerun skips stored txs), then fans the trace out as
  `CollectionTraceWorker` batches.

  Every job carries the run's start time. A trace batch skips items traced
  since then, so a resumed run only does the remainder, and the last batch to
  finish logs the run's summary.
  """
  use Oban.Worker,
    queue: :collections,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:slug],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  import Ecto.Query

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.Workers.CollectionTraceWorker

  @batch 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"slug" => slug, "run_started_at" => started} = args}) do
    with {:ok, cid} <- resolve(slug),
         {:ok, hint} <- hint(cid) do
      sync = OrdinalCollections.sync(cid, hint)

      ids =
        Bitblocks.Repo.all(
          from i in Item, where: i.collection_id == ^cid, order_by: i.id, select: i.id
        )

      if Map.get(args, "trace", true) do
        ids
        |> Enum.chunk_every(@batch)
        |> Enum.each(fn batch ->
          Oban.insert!(
            CollectionTraceWorker.new(%{slug: slug, ids: batch, run_started_at: started})
          )
        end)
      end

      Logger.info(
        "collection sync #{slug}: walked #{sync.mints} mints, #{sync.items} items, " <>
          "#{sync.rejected} rejected; #{ceil(length(ids) / @batch)} trace batches enqueued"
      )

      :ok
    end
  end

  defp resolve(slug) do
    case OrdinalCollections.resolve(slug) ||
           if(slug =~ ~r/\A[0-9a-f]{64}_\d+\z/, do: slug) do
      nil -> {:cancel, :unknown_collection}
      cid -> {:ok, cid}
    end
  end

  defp hint(cid) do
    case OrdinalCollections.config_for(cid) do
      %{hint: :catalog, catalog: catalog} -> {:ok, catalog.mint_txids()}
      _ -> Bitblocks.Ordinals.Gorillapool.collection_mint_txids(cid)
    end
  end
end
