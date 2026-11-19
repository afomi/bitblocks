defmodule Bitblocks.Workers.DownloadPrepareWorker do
  @moduledoc """
  Prepares a paid download's files (`Bitblocks.Downloads.Purchases.prepare/2`,
  https://github.com/afomi/bitblocks/issues/111): each block object's sha256,
  then the manifest's. Queued by the `checkout.session.completed` webhook.

  Bounded runs of about a minute; a run that isn't done snoozes briefly and
  carries on from what it has kept, so a deploy or a large range never
  loses work. A store error retries with Oban's backoff.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:purchase_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Bitblocks.Downloads.Purchases

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"purchase_id" => id}}) do
    case Purchases.get(id) do
      nil ->
        {:cancel, :no_purchase}

      purchase ->
        case Purchases.prepare(purchase) do
          {:ok, _} -> :ok
          {:continue, _} -> {:snooze, 5}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
