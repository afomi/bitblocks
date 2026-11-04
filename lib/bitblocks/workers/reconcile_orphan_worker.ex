defmodule Bitblocks.Workers.ReconcileOrphanWorker do
  @moduledoc """
  Reconciles one orphaned block's transaction rows after tip sync resolves a
  reorg (#34). See `Bitblocks.Reorgs.Reconcile`.

  Enqueued by `SyncHeadersWorker` for each orphan it deletes, a few minutes
  out, so the replacement block's own tx fetch usually runs first and moves
  the shared transactions itself. Rows it can't place yet (a lookup failed,
  or their block isn't stored) are an error, so Oban tries again with
  backoff; the work is idempotent.
  """

  use Oban.Worker,
    queue: :blocks,
    max_attempts: 5,
    unique: [period: 3600, fields: [:args], keys: [:orphan_hash]]

  require Logger

  alias Bitblocks.Reorgs.Reconcile

  @doc "Builds the job for `orphan_hash`, `delay` seconds from now."
  def job(orphan_hash, delay \\ 600) do
    new(%{"orphan_hash" => orphan_hash}, schedule_in: delay)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"orphan_hash" => orphan_hash}}) do
    case Reconcile.run(orphan_hash, apply: true) do
      {:ok, %{result: %{remaining: 0}}} ->
        :ok

      {:ok, %{result: %{remaining: n}}} ->
        {:error, {:unreconciled, n}}

      {:error, :block_still_stored} ->
        {:cancel, :block_still_stored}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
