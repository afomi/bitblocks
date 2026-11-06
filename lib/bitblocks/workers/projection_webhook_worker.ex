defmodule Bitblocks.Workers.ProjectionWebhookWorker do
  @moduledoc """
  Delivers one projection webhook event (#29 step 4). See
  `Bitblocks.Projections.Webhook` for the payload and signature.

  A non-2xx response or transport error returns `{:error, _}`, so Oban retries
  with its default backoff (15s + attempt^4), up to 10 attempts: about four
  hours of retries in all. A paused or deleted projection cancels instead of posting.

  The target is checked first (`WebhookTarget`): a private one cancels and is
  never retried, and a name that doesn't resolve retries. A delivery given up
  on is recorded on the projection (`Projections.record_webhook_failure/3`), so
  /syncing can show it after Oban has pruned the job.

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
  alias Bitblocks.Projections.{Webhook, WebhookTarget}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"projection_id" => id, "event" => event} = args} = job) do
    case Projections.get(id) do
      nil ->
        {:cancel, :projection_not_found}

      %{status: "paused"} ->
        {:cancel, :paused}

      %{webhook_url: nil} ->
        {:cancel, :no_webhook}

      projection ->
        case WebhookTarget.resolve(projection.webhook_url) do
          {:ok, url, extra_headers} ->
            body = Webhook.body(projection, args)
            headers = Webhook.headers(event, body, projection.webhook_secret) ++ extra_headers
            client().post(url, body, headers) |> result() |> given_up(projection, event, job)

          {:refused, reason} ->
            Projections.record_webhook_failure(projection, event, "refused: #{reason}")
            {:cancel, {:refused, reason}}

          {:retry, reason} ->
            given_up({:error, reason}, projection, event, job)
        end
    end
  end

  defp result({:ok, status}) when status in 200..299, do: :ok
  defp result({:ok, status}), do: {:error, {:http_status, status}}
  defp result({:error, reason}), do: {:error, reason}

  # Oban discards a job after its last attempt fails.
  defp given_up({:error, reason} = error, projection, event, %{attempt: n, max_attempts: n}) do
    Projections.record_webhook_failure(projection, event, inspect(reason))
    error
  end

  defp given_up(result, _projection, _event, _job), do: result

  defp client, do: Application.get_env(:bitblocks, :projection_webhook_client, Webhook)
end
