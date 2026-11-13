defmodule Bitblocks.Workers.FlowTilesWorker do
  @moduledoc """
  Builds `/tx-graph` flow tiles (`Bitblocks.FlowTiles.build/1`, #67) on the
  `:chain_tiles` queue (concurrency 1), so it never shares a slot with sync.

  The cron enqueues one every five minutes: it resumes after the highest
  height built, up to `Sync.complete_through/0`, and does nothing until a
  person has started a build (`Bitblocks.Release.build_flow_tiles/1`).
  A run stops at its time budget; while behind, it queues the next run, so a
  long build is a chain of short jobs that a deploy only pauses.
  """

  use Oban.Worker,
    queue: :chain_tiles,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:worker],
      states: [:available, :scheduled, :retryable]
    ]

  alias Bitblocks.FlowTiles

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts = if is_integer(args["from"]), do: [from: args["from"]], else: []

    case FlowTiles.build(opts) do
      {:ok, %{behind: true}} ->
        {:ok, _} = %{} |> new(schedule_in: 5) |> Oban.insert()
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
