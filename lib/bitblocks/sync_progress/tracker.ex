defmodule Bitblocks.SyncProgress.Tracker do
  @moduledoc """
  Counts one block's progress as a tx-fetch worker walks its txid list, and
  reports it over PubSub so `/syncing` never has to count anything itself.

  The worker hands each chunk of txids to `chunk/2` after it has stored the
  chunk's gaps. One bounded query (at most a chunk of txids, served by the
  unique `transactions_txid_index`) tells how many of them are stored and how
  many carry the current `TransactionParser.script_analysis_version`.
  Running totals are kept here, in the worker process.

  Reports go out at most once a second per block (`@min_interval_ms`), plus
  a final one from `finish/1`, so a block with a million txs sends about one
  message a second however fast its chunks go by.

  A block job's run resumes at the chunk its last run reached; the chunks
  before it were all stored, and analyzed on ingest, by that same job, so
  they start the totals as both stored and processed.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.{Repo, TransactionParser}

  @topic "sync_progress"
  @min_interval_ms 1_000

  defstruct [
    :hash,
    :height,
    :time,
    :num_tx,
    total: 0,
    stored: 0,
    processed: 0,
    last_report_at: nil
  ]

  @doc "The PubSub topic progress reports go to."
  def topic, do: @topic

  @doc """
  Starts tracking `block`, expecting `total` txs, of which the first `done`
  are already stored. Reports at once.
  """
  def new(%Block{} = block, total, done \\ 0) do
    %__MODULE__{
      hash: block.hash,
      height: block.height,
      time: block.time,
      num_tx: block.num_tx,
      total: total,
      stored: done,
      processed: done
    }
    |> report(:force)
  end

  @doc "Adds one walked chunk of txids to the totals."
  def chunk(%__MODULE__{} = tracker, []), do: tracker

  def chunk(%__MODULE__{} = tracker, txids) when is_list(txids) do
    {stored, processed} = count(txids)

    %{tracker | stored: tracker.stored + stored, processed: tracker.processed + processed}
    |> report(:throttled)
  end

  @doc "Sends the final totals, whatever the throttle says."
  def finish(%__MODULE__{} = tracker), do: report(tracker, :force)

  @doc """
  How many of `txids` are stored, and how many of those are analyzed at the
  current analyzer version. One query; keep `txids` to a chunk.
  """
  def count(txids) when is_list(txids) do
    version = TransactionParser.script_analysis_version()

    from(t in Transaction,
      where: t.txid in ^txids,
      select: {
        count(),
        filter(count(), t.script_analysis_version >= ^version)
      }
    )
    |> Repo.one()
  end

  defp report(tracker, mode) do
    now = System.monotonic_time(:millisecond)

    if mode == :force or is_nil(tracker.last_report_at) or
         now - tracker.last_report_at >= @min_interval_ms do
      Phoenix.PubSub.broadcast(Bitblocks.PubSub, @topic, {:sync_progress, payload(tracker)})
      %{tracker | last_report_at: now}
    else
      tracker
    end
  end

  defp payload(tracker) do
    Map.take(tracker, [:hash, :height, :time, :num_tx, :total, :stored, :processed])
  end
end
