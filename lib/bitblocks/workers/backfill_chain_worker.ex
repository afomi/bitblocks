defmodule Bitblocks.Workers.BackfillChainWorker do
  @moduledoc """
  One range of a backfill chain (`Bitblocks.BackfillChains`), on its own lane
  (`:backfills`, concurrency 1), so a long range never holds up the sync or
  `CatchUpBlockWorker`. Unique on the chain and range while queued. Attempts
  cover restarts as well as errors, so a deploy never ends a chain; when they
  run out the chain reads `failed` and can be resumed.
  """

  use Oban.Worker,
    queue: :backfills,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:chain_id, :from],
      states: [:available, :scheduled, :retryable]
    ]

  alias Bitblocks.BackfillChains

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"chain_id" => id, "from" => from},
        attempt: attempt,
        max_attempts: max
      }) do
    BackfillChains.run_range(id, from, attempt >= max)
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(attempt * 60, 900)
end
