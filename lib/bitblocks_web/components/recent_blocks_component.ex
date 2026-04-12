defmodule BitblocksWeb.RecentBlocksComponent do
  @moduledoc """
  Displays recent blocks with time intervals between them.
  Shows the chain's heartbeat — how frequently blocks are being mined.
  """
  use Phoenix.Component

  attr :blocks, :list, required: true

  def recent_blocks(assigns) do
    blocks = assigns.blocks || []

    # Pair each block with the time delta to the previous (older) block
    blocks_with_deltas =
      blocks
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [newer, older] ->
        delta = newer.time - older.time
        {newer, delta}
      end)

    # The oldest block has no delta
    last_block = List.last(blocks)

    blocks_with_deltas =
      if last_block do
        blocks_with_deltas ++ [{last_block, nil}]
      else
        blocks_with_deltas
      end

    assigns = assign(assigns, :blocks_with_deltas, blocks_with_deltas)

    ~H"""
    <div>
      <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-4">
        Recent Blocks
      </p>
      <div class="border-t border-neutral-800">
        <%= for {block, delta} <- @blocks_with_deltas do %>
          <a
            href={"/blocks/#{block.height}"}
            class="flex items-center justify-between py-3 border-b border-neutral-800 group"
          >
            <div class="flex items-center gap-4">
              <span class="font-mono text-sm text-neutral-50 tabular-nums group-hover:text-brand transition-colors duration-150">
                {block.height}
              </span>
              <span class="text-xs text-neutral-500 tabular-nums">
                {format_block_time(block.time)}
              </span>
            </div>
            <div class="flex items-center gap-4">
              <span
                :if={block.num_tx}
                class="font-mono text-xs text-neutral-500 tabular-nums"
              >
                {block.num_tx} tx
              </span>
              <span
                :if={delta}
                class={"font-mono text-xs tabular-nums #{interval_color(delta)}"}
              >
                +{format_interval(delta)}
              </span>
            </div>
          </a>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_block_time(unix) when is_integer(unix) do
    DateTime.from_unix!(unix)
    |> Calendar.strftime("%H:%M UTC")
  end

  defp format_block_time(_), do: ""

  defp format_interval(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_interval(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_interval(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  # Color based on how long the interval was — gives a visual sense of cadence
  defp interval_color(seconds) when seconds <= 600, do: "text-green-500"
  defp interval_color(seconds) when seconds <= 1800, do: "text-neutral-500"
  defp interval_color(_seconds), do: "text-amber-400"
end
