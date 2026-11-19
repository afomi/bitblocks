defmodule BitblocksWeb.UsageLive do
  @moduledoc """
  `/usage`, admin only: what callers used, by endpoint class and by caller,
  over the last day, week or 30 days (`?hours=24|168|720`), from the hourly
  rollups (`Bitblocks.Usage`, https://github.com/afomi/bitblocks/issues/61).
  Measured, nobody charged; the numbers a rate would be set from.
  """

  use BitblocksWeb, :live_view

  alias Bitblocks.Usage

  import BitblocksWeb.Sats, only: [delimit: 1]

  @windows [{24, "Last 24 hours"}, {168, "Last 7 days"}, {720, "Last 30 days"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Usage", windows: @windows)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    hours =
      case Integer.parse(params["hours"] || "") do
        {n, ""} when n in [24, 168, 720] -> n
        _ -> 24
      end

    {:noreply, assign(socket, hours: hours, report: Usage.report(hours: hours, limit: 50))}
  end

  @doc false
  def bytes(n), do: Usage.format_bytes(n)

  @doc false
  def seconds(us), do: "#{Float.round(us / 1_000_000, 1)} s"

  @doc false
  def upstream(u), do: u.node_calls + u.woc_calls + u.coingecko_calls + u.other_calls

  @doc false
  def mean(nil, _key), do: "–"
  def mean(per_request, :response_bytes), do: bytes(per_request.response_bytes)
  def mean(per_request, key), do: "#{Map.fetch!(per_request, key)} ms"
end
