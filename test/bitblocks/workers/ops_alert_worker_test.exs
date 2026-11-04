defmodule Bitblocks.Workers.OpsAlertWorkerTest do
  use Bitblocks.DataCase, async: false

  alias Bitblocks.Workers.OpsAlertWorker

  test "runs a health check and alerts on what it finds" do
    Bitblocks.Ops.reset_alerts()
    assert :ok = perform_job(OpsAlertWorker, %{})
  end

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})
end
