defmodule BitblocksWeb.HealthLine do
  @moduledoc """
  The one answer /sync and /status lead with (#44): how far our index is
  complete and how fresh it is, our node's state and lag, failed blocks, and
  whether the sync is moving, paused or stalled.

  Renders `Bitblocks.Ops.health/0`, the same map `/api/v1/status` serves and
  the alert cron reads, so the pages, the API and the emails agree.
  """
  use Phoenix.Component

  embed_templates "health_line/*"

  attr :health, :map, required: true, doc: "Bitblocks.Ops.health/0"
  attr :id, :string, default: "health-line"
  attr :class, :string, default: "mb-6 text-sm text-gray-700 dark:text-gray-300"
  def health_line(assigns)

  @doc false
  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def number(n), do: to_string(n)

  @doc false
  def complete?(%{index: %{complete_through: n}}) when is_integer(n) and n >= 0, do: true
  def complete?(_), do: false

  @doc false
  # Blocks between what is complete and what our node has validated.
  def behind_node(%{index: %{complete_through: through}, node: %{blocks: blocks}})
      when is_integer(through) and is_integer(blocks) and blocks > through,
      do: blocks - through

  def behind_node(_), do: nil

  @doc false
  # Whole minutes from `iso` to the health's `as_of`, or nil.
  def minutes_ago(nil, _as_of), do: nil

  def minutes_ago(iso, as_of) do
    with {:ok, at, _} <- DateTime.from_iso8601(iso),
         {:ok, now, _} <- DateTime.from_iso8601(as_of) do
      max(div(DateTime.diff(now, at), 60), 0)
    else
      _ -> nil
    end
  end

  @doc false
  def failed_text(0), do: "No blocks have failed."
  def failed_text(1), do: "1 block failed and is retrying."
  def failed_text(n) when is_integer(n), do: "#{number(n)} blocks failed and are retrying."
  def failed_text(_), do: nil

  @doc false
  def progress_text(%{index: %{paused: true}}), do: "The sync is paused by an operator."

  def progress_text(%{index: %{stalled: "headers"}}),
    do: "The sync has stalled: no new header has landed for over an hour."

  def progress_text(%{index: %{stalled: "blocks"}}),
    do: "The sync has stalled: no block has completed for over an hour."

  def progress_text(_), do: "The sync is progressing."
end
