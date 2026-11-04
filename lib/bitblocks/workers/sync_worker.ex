defmodule Bitblocks.Workers.SyncWorker do
  @moduledoc """
  The per-minute cron's check on the sync loop: makes sure
  `Bitblocks.Sync.Coordinator` is running on this node and nudges it.
  The coordinator leads the sync (docs/SYNCING.md); this job only keeps it
  alive. Unique across queued and running states, so ticks never pile up.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Bitblocks.Sync.Coordinator.ensure_running()
    :ok
  end
end
