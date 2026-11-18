defmodule Bitblocks.Workers.X402ReconcileWorker do
  @moduledoc """
  Every 10 minutes: records in Stripe each settled x402 payment that has no
  PaymentIntent yet (`Bitblocks.Payments.X402.reconcile/1`, over
  `X402.Reconciler`). Well inside Stripe's 24-hour idempotency window, so a
  payment the request did record but couldn't mark returns the same
  PaymentIntent. A no-op while x402 is off.

  A failure to record is logged by x402_ex at error level with the
  transaction hash, and the row waits for the next run.
  """
  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 540]

  @impl Oban.Worker
  def perform(_job) do
    case Bitblocks.Payments.X402.reconcile() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
