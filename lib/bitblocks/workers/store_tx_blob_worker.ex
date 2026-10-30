defmodule Bitblocks.Workers.StoreTxBlobWorker do
  @moduledoc """
  Writes one tx's raw bytes to the blob store (`Bitblocks.TxStore.store/1`).
  Failures (bucket missing, no write permission, S3 down) return an error so
  Oban retries with backoff; `blob_stored_at` stays null until a verified
  write. Unique per txid while pending.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity, keys: [:txid], states: [:available, :scheduled, :retryable]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"txid" => txid}}), do: Bitblocks.TxStore.store(txid)
end
