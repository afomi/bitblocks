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
    <section aria-labelledby="recent-blocks-heading">
      <h2
        id="recent-blocks-heading"
        class="text-lg font-semibold text-gray-900 dark:text-white mb-2"
      >
        Recent blocks
      </h2>
      <div class="border-t border-gray-200 dark:border-gray-700">
        <a
          :for={{block, delta} <- @blocks_with_deltas}
          href={"/blocks/#{block.height}"}
          class="group flex items-center justify-between gap-4 border-b border-gray-200 py-3 dark:border-gray-700"
        >
          <span class="flex items-center gap-4">
            <span class="font-mono text-sm tabular-nums text-gray-900 group-hover:text-brand-strong dark:text-white dark:group-hover:text-brand">
              {block.height}
            </span>
            <span class="text-xs tabular-nums text-gray-600 dark:text-gray-400">
              {format_block_time(block.time)}
            </span>
          </span>
          <span class="flex items-center gap-4 font-mono text-xs tabular-nums text-gray-600 dark:text-gray-400">
            <span :if={block.num_tx}>
              {format_count(block.num_tx)} tx
            </span>
            <span
              class="hidden sm:inline"
              title="Fees paid to the miner, and the miner's reward (subsidy plus fees)"
            >
              fees {BitblocksWeb.Sats.block_sats(block, :fees)}
              · reward {BitblocksWeb.Sats.block_bsv(block, :miner_reward)}
            </span>
            <span
              :if={delta}
              class={interval_color(delta)}
              title="Time since the block before it"
            >
              +{format_interval(delta)}
            </span>
          </span>
        </a>
      </div>
      <a
        href="/blocks"
        class="mt-3 inline-block text-sm text-blue-700 hover:text-blue-900 dark:text-blue-400 dark:hover:text-blue-300"
      >
        All blocks
      </a>
    </section>
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

  # Color by how long the interval was, for a sense of cadence. 700 shades
  # clear 4.5:1 on white, 400 shades on gray-900 (DESIGN.md).
  defp interval_color(seconds) when seconds <= 600, do: "text-green-700 dark:text-green-400"
  defp interval_color(seconds) when seconds <= 1800, do: nil
  defp interval_color(_seconds), do: "text-amber-700 dark:text-amber-400"

  # 23363 -> "23,363"
  defp format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp format_count(n), do: to_string(n)
end
