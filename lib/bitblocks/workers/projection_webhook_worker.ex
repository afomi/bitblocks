defmodule Bitblocks.Workers.ProjectionWebhookWorker do
  @moduledoc """
  Delivers one projection webhook event (#29 step 4). See
  `Bitblocks.Projections.Webhook` for the payload and signature.

  A non-2xx response or transport error returns `{:error, _}`, so Oban retries
  with its default backoff (15s + attempt^4), up to 10 attempts: about four
  hours of retries in all. A paused or deleted projection cancels instead of posting.

  `tx` events are unique on `{projection, txid, block_hash}` across every job
  state, so one match is enqueued once even if its block completes twice; the
  same tx re-mined after a reorg has a new block hash and is delivered again.
  """
  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:projection_id, :event, :txid, :block_hash],
      states: [:available, :scheduled, :executing, :retryable, :completed, :discarded, :cancelled]
    ]

  alias Bitblocks.Projections
  alias Bitblocks.Projections.Webhook

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"projection_id" => id, "event" => event} = args}) do
    case Projections.get(id) do
      nil ->
        {:cancel, :projection_not_found}

      %{status: "paused"} ->
        {:cancel, :paused}

      %{webhook_url: nil} ->
        {:cancel, :no_webhook}

      projection ->
        body = Webhook.body(projection, args)
        headers = Webhook.headers(event, body, projection.webhook_secret)

        case client().post(projection.webhook_url, body, headers) do
          {:ok, status} when status in 200..299 -> :ok
          {:ok, status} -> {:error, {:http_status, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp client, do: Application.get_env(:bitblocks, :projection_webhook_client, Webhook)
end
