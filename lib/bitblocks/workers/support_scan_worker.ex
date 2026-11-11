defmodule Bitblocks.Workers.SupportScanWorker do
  @moduledoc """
  Reads the newest blocks for gifts to the donation address
  (`Bitblocks.Support.Scan.run/1`, #74), every two minutes on its own lane
  (`:support_scan`, concurrency 1), one block at a time for a bounded time,
  so it never holds a sync slot. A no-op until `scan_from_height` is set.
  """

  use Oban.Worker,
    queue: :support_scan,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _stats} = Bitblocks.Support.Scan.run()
    :ok
  end
end
