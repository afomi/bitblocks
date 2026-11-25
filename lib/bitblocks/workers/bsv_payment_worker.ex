defmodule Bitblocks.Workers.BsvPaymentWorker do
  @moduledoc """
  Every minute: follows each accepted BSV 402 payment until it is settled,
  dropped or conflicted (`Bitblocks.Payments.Bsv402.Confirmation`,
  docs/BSV_402.md, slice 4). A no-op (one query) while no payment is open.

  On the default lane at a low priority, so it never waits ahead of other
  work; nothing on a reader node, which runs no queues and no cron
  (`Bitblocks.NodeRole`). Unique across nodes, so two writers never ask our
  node about the same payment at once. Each row carries its own backoff, and
  a run checks at most 100 of them; a failed run is retried twice, then left
  to the next minute.
  """

  use Oban.Worker,
    queue: :default,
    priority: 5,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Bitblocks.Payments.Bsv402.Confirmation.run()
    :ok
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 15 * attempt
end
