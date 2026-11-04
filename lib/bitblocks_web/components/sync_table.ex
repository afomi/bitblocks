defmodule BitblocksWeb.SyncTable do
  @moduledoc """
  The sync's block table, shared by /syncing and /sync: "Complete through
  block X of N known", the concurrency in use and its limit, and the blocks
  around the cursor in height order, each with its stages (header, tx
  count, txs fetched, verified), worker slot and retry state.

  Renders `Bitblocks.SyncProgress.snapshot().sync` (from `Sync.overview/0`);
  never queries. Each stage is text with an icon, never colour alone.
  """
  use Phoenix.Component

  embed_templates "sync_table/*"

  attr :sync, :map,
    default: nil,
    doc: "Sync.overview/0 with :fetched per row, or nil before the first count"

  attr :id, :string, default: "sync-table"
  def sync_table(assigns)

  @doc false
  def number(nil), do: "—"

  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc false
  def complete?(%{complete_through: n}) when is_integer(n) and n >= 0, do: true
  def complete?(_), do: false

  @doc false
  def retry_text(%{failures: f, next_retry_at: %DateTime{} = at}) when is_integer(f) and f > 0,
    do: "Failed #{f} in a row; next try #{Calendar.strftime(at, "%H:%M UTC")}"

  def retry_text(%{failures: f}) when is_integer(f) and f > 0,
    do: "Failed #{f} in a row; retrying"

  def retry_text(_row), do: "No failures"

  @doc false
  def worker_text(%{slot: slot, job_state: "executing"}) when is_integer(slot),
    do: "Slot #{slot}, working"

  def worker_text(%{slot: slot, job_state: "scheduled"}) when is_integer(slot),
    do: "Slot #{slot}, waiting"

  def worker_text(%{slot: slot}) when is_integer(slot), do: "Slot #{slot}, queued"
  def worker_text(%{job_state: state}) when is_binary(state), do: "Manual fetch, #{state}"
  def worker_text(%{sync_state: "completed"}), do: "Done"
  def worker_text(_row), do: "Waiting for a slot"
end
