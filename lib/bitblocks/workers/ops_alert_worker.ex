defmodule Bitblocks.Workers.OpsAlertWorker do
  @moduledoc """
  Every five minutes: checks `Bitblocks.Ops.health/0` and emails each problem
  (node unreachable; index stalled: headers not following the node, or no
  block completing while blocks wait) at most every six hours.
  Exists so an outage is loud: the node was down from July to November 2026
  and nothing said so.
  """
  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 240]

  @impl Oban.Worker
  def perform(_job) do
    Bitblocks.Ops.health() |> Bitblocks.Ops.alert()
    :ok
  end
end
