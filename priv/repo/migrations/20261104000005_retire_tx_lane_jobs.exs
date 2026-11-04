defmodule Bitblocks.Repo.Migrations.RetireTxLaneJobs do
  @moduledoc """
  The sync loop (docs/SYNCING.md) replaced the `transactions_tip` and
  `transactions_backfill` queues and BackfillTransactionsWorker. No queue runs
  those jobs any more, so cancel the ones still waiting; the loop reaches
  their blocks in order by itself. Touches `oban_jobs` only.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE oban_jobs
    SET state = 'cancelled', cancelled_at = now()
    WHERE state IN ('available', 'scheduled', 'retryable', 'executing')
      AND (queue IN ('transactions', 'transactions_tip', 'transactions_backfill')
           OR worker = 'Bitblocks.Workers.BackfillTransactionsWorker')
    """)
  end

  def down, do: :ok
end
