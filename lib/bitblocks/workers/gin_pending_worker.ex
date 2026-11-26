defmodule Bitblocks.Workers.GinPendingWorker do
  @moduledoc """
  Every minute, on the `:maintenance` lane (concurrency 1), cleans the GIN
  indexes' pending lists on `transactions` (`Bitblocks.DB.GinPending`, #87),
  so no sync insert has to merge one. Unique, so a slow run is never doubled.
  `config :bitblocks, :gin_pending_cleanup, false` turns it off.

  Unique over jobs inserted in the last #{div(300, 60)} minutes, not forever. A run
  takes about 16 s (69 s the longest seen, 2026-11-24), so a live run still
  blocks the next cron insert. But a deploy's SIGTERM can leave a run marked
  `executing` with no process behind it, and with `period: :infinity` that
  orphan blocked every cron insert until Lifeline freed it 30 minutes later,
  while the sync's inserts merged the pending lists themselves and were
  canceled at 50 s (https://github.com/afomi/bitblocks/issues/212). With a
  period, the orphan stops counting after 5 minutes. `:executing` stays in the
  states, since both prod hosts run the `:maintenance` lane and dropping it
  would let two runs overlap.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [
      period: 300,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Application.get_env(:bitblocks, :gin_pending_cleanup, true) do
      Bitblocks.DB.GinPending.run()
    end

    :ok
  end
end
