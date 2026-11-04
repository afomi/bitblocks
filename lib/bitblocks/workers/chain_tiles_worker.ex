defmodule Bitblocks.Workers.ChainTilesWorker do
  @moduledoc """
  Builds chain-scrubber tiles (`Bitblocks.ChainTiles.build/1`) on its own
  queue (`:chain_tiles`, concurrency 1), so it never shares a slot with
  the sync loop.

  The cron enqueues `mode: incremental` every five minutes; that run is a
  no-op (one index probe) when no block changed, and does nothing at all
  until a person has run a full build. `mode: full` is only ever enqueued by
  `Bitblocks.Release.build_chain_tiles/1`. One job at a time per worker.
  """

  use Oban.Worker,
    queue: :chain_tiles,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Bitblocks.ChainTiles

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    mode = if args["mode"] == "full", do: :full, else: :incremental

    case ChainTiles.build(mode: mode) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
