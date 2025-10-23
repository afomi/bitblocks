defmodule Bitblocks.EventPlayground.NoteProjector do
  @moduledoc """
  Applies note events to derive the latest materialised state for the playground.
  """

  alias Bitblocks.EventPlayground.Event

  @type projection :: %{
          optional(:title) => String.t() | nil,
          optional(:body) => String.t() | nil,
          optional(:deleted_at) => DateTime.t() | nil
        }

  @spec apply([Event.t()]) :: projection
  def apply(events) do
    Enum.reduce(events, %{}, fn
      %Event{event_type: "NoteCreated", payload: payload}, acc ->
        acc
        |> Map.put(:title, fetch(payload, "title"))
        |> Map.put(:body, fetch(payload, "body"))
        |> Map.put(:deleted_at, nil)

      %Event{event_type: "NoteTitleUpdated", payload: payload}, acc ->
        Map.put(acc, :title, fetch(payload, "title") || acc[:title])

      %Event{event_type: "NoteBodyUpdated", payload: payload}, acc ->
        Map.put(acc, :body, fetch(payload, "body") || acc[:body])

      %Event{event_type: "NoteDeleted", payload: payload}, acc ->
        Map.put(acc, :deleted_at, parse_timestamp(payload["timestamp"]))

      _event, acc ->
        acc
    end)
  end

  defp fetch(map, key) when is_map(map) do
    map[key] || map[to_string(key)]
  end

  defp fetch(_, _), do: nil

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(%DateTime{} = dt), do: dt

  defp parse_timestamp(binary) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()
end
