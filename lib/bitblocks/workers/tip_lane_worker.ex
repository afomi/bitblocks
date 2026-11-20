defmodule Bitblocks.Workers.TipLaneWorker do
  @moduledoc """
  Runs the tip lanes (`Bitblocks.TipLane.run/1`, #139) every minute on their
  own lane (`:tip_lane`, concurrency 1), one block at a time for a bounded
  time, so a lane never holds a sync slot's job. A no-op (one query) until
  `Release.start_tip_lane/2` starts a lane; nothing on a reader node, which
  runs no queues and no cron.

  Unique across nodes and states, so two writers never run two lanes' reads
  at once. A run cut off by a deploy leaves its block `reading`, which the
  next run reads again.
  """

  use Oban.Worker,
    queue: :tip_lane,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _stats} = Bitblocks.TipLane.run()
    :ok
  end
end
