defmodule BitblocksWeb.ForkGraphLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.ForkTracker

  @tape_refresh_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    snapshot = ForkTracker.snapshot()
    events = ForkTracker.recent_events(25)

    socket =
      socket
      |> assign(
        graph_version: snapshot[:version] || 0,
        tips: format_tips(snapshot[:tips] || []),
        events: events,
        base_height: snapshot[:base_height],
        branch_offsets: snapshot[:branch_offsets] || %{},
        last_delta: nil
      )

    socket =
      if connected?(socket) do
        ForkTracker.subscribe()
        schedule_tape_refresh()
        push_event(socket, "fork_snapshot", snapshot)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:fork_update, delta}, socket) do
    socket =
      socket
      |> assign(
        graph_version: delta.version,
        tips: format_tips(delta.tips),
        base_height: delta.base_height,
        branch_offsets: delta.branch_offsets,
        last_delta: delta
      )
      |> push_event("fork_delta", delta)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh_tape, socket) do
    if connected?(socket) do
      schedule_tape_refresh()
    end

    {:noreply, assign(socket, events: ForkTracker.recent_events(25))}
  end

  @impl true
  def handle_event("force-poll", _params, socket) do
    ForkTracker.force_poll()
    {:noreply, socket}
  end

  # Template: fork_graph_live.html.heex

  defp format_tips(tips) when is_list(tips) do
    tips
    |> Enum.sort_by(& &1.height, :desc)
  end

  defp format_tips(_), do: []

  defp status_class(:main),
    do:
      "inline-flex items-center rounded-full bg-emerald-500/10 text-emerald-400 px-2 py-0.5 text-xs"

  defp status_class(:valid_fork),
    do: "inline-flex items-center rounded-full bg-amber-500/10 text-amber-300 px-2 py-0.5 text-xs"

  defp status_class(:fork), do: status_class(:valid_fork)

  defp status_class(:invalid),
    do: "inline-flex items-center rounded-full bg-rose-500/10 text-rose-400 px-2 py-0.5 text-xs"

  defp status_class(_),
    do: "inline-flex items-center rounded-full bg-slate-500/10 text-slate-300 px-2 py-0.5 text-xs"

  defp schedule_tape_refresh do
    Process.send_after(self(), :refresh_tape, @tape_refresh_interval)
  end
end
