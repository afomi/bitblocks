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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <section class="bg-neutral-950 border border-neutral-800 rounded-xl">
        <div class="flex items-center justify-between px-5 py-3">
          <h2 class="text-lg font-semibold text-neutral-100">
            Fork Topology
          </h2>
          <button
            type="button"
            class="px-3 py-1 text-sm rounded-lg bg-neutral-800 text-neutral-200 hover:bg-neutral-700"
            phx-click="force-poll"
          >
            Refresh tips
          </button>
        </div>
        <div
          id="fork-graph"
          phx-hook="ForkGraph"
          data-base-height={@base_height}
          class="w-full h-[520px]"
        >
        </div>
      </section>

      <section class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <article class="lg:col-span-2 bg-white/5 border border-neutral-800 rounded-xl p-4">
          <h3 class="text-sm font-semibold text-neutral-200 mb-3">
            Active chain tips
          </h3>
          <div class="overflow-x-auto">
            <table class="w-full text-left text-sm text-neutral-300">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-neutral-500">
                  <th class="py-2 pr-4">Hash</th>
                  <th class="py-2 pr-4">Height</th>
                  <th class="py-2 pr-4">Status</th>
                  <th class="py-2 pr-4">Branch</th>
                  <th class="py-2 pr-4">Updated</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-neutral-800">
                <%= for tip <- @tips do %>
                  <tr>
                    <td class="py-2 pr-4 font-mono text-xs">
                      <%= String.slice(tip.hash, 0, 16) %>…
                    </td>
                    <td class="py-2 pr-4"><%= tip.height %></td>
                    <td class="py-2 pr-4">
                      <span class={status_class(tip.status)}>
                        <%= tip.status %>
                      </span>
                    </td>
                    <td class="py-2 pr-4">
                      <%= tip.branch_len %>
                    </td>
                    <td class="py-2 pr-4 text-xs text-neutral-500">
                      <%= tip.updated_at || "—" %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </article>

        <article class="bg-white/5 border border-neutral-800 rounded-xl p-4">
          <h3 class="text-sm font-semibold text-neutral-200 mb-3">
            Fork tape (recent)
          </h3>
          <div class="max-h-[220px] overflow-y-auto font-mono text-xs space-y-1 text-neutral-400">
            <%= if @events == [] do %>
              <p>No fork contention recorded yet.</p>
            <% else %>
              <%= for line <- @events do %>
                <p><%= line %></p>
              <% end %>
            <% end %>
          </div>
        </article>
      </section>
    </div>
    """
  end

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
