defmodule Bitblocks.Workers.GinPendingWorker do
  @moduledoc """
  Every minute, on the `:maintenance` lane (concurrency 1), cleans the GIN
  indexes' pending lists on `transactions` (`Bitblocks.DB.GinPending`, #87),
  so no sync insert has to merge one. Unique, so a slow run is never doubled.
  `config :bitblocks, :gin_pending_cleanup, false` turns it off.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [
      period: :infinity,
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
