defmodule Bitblocks.Workers.BackfillTransactionsWorker do
  @moduledoc """
  Background job that walks from block 0 to chain tip, ensuring every block
  has its transactions fetched.

  For each block: if sync_state is "completed", skip. Otherwise, queue a
  FetchTransactionsWorker job to download its transactions.

  Progress is ratcheted via sync_state. Restarting the app or the job
  always resumes from the lowest non-completed block.

  Processes one batch at a time, waits for it to drain, then re-enqueues
  itself for the next batch.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.backfill_txs()'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_txs(batch_size: 50)'

  ## Monitoring

      bin/bitblocks rpc 'Bitblocks.Release.status()'
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, fields: [:worker]]

  require Logger
  alias Bitblocks.{Repo, Chain, Chain.Block}
  import Ecto.Query

  @default_batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch_size = Map.get(args, "batch_size", @default_batch_size)

    # Reset stuck blocks so they're retryable
    {reset_count, _} =
      from(b in Block,
        where: b.sync_state in ["failed", "txs_queued", "txs_syncing"]
      )
      |> Repo.update_all(set: [sync_state: "header_only"])

    if reset_count > 0 do
      Logger.info("BackfillTxs: reset #{reset_count} stuck blocks")
    end

    # Find the next batch: lowest non-completed blocks
    blocks =
      from(b in Block,
        where: b.sync_state != "completed",
        order_by: [asc: b.height],
        limit: ^batch_size
      )
      |> Repo.all()

    if blocks == [] do
      Logger.info("BackfillTxs: all blocks complete — done!")
      :ok
    else
      first = hd(blocks).height
      last = List.last(blocks).height

      remaining =
        from(b in Block, where: b.sync_state != "completed", select: count())
        |> Repo.one()

      Logger.info(
        "BackfillTxs: queuing #{length(blocks)} blocks " <>
          "(#{first}..#{last}), #{remaining} remaining"
      )

      Enum.each(blocks, &Chain.queue_transaction_fetch/1)

      # Wait for this batch to finish before scheduling the next
      wait_for_tx_jobs()

      # Schedule the next batch
      %{"batch_size" => batch_size}
      |> __MODULE__.new()
      |> Oban.insert()

      :ok
    end
  end

  defp wait_for_tx_jobs do
    Stream.repeatedly(fn ->
      pending =
        from(j in Oban.Job,
          where: j.queue == "transactions",
          where: j.state in ["available", "executing", "scheduled"],
          select: count()
        )
        |> Repo.one()

      if pending == 0 do
        :drained
      else
        Process.sleep(5_000)
        :waiting
      end
    end)
    |> Enum.find(&(&1 != :waiting))
  end
end
