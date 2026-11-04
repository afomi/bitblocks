defmodule BitblocksWeb.NextBlockComponent do
  @moduledoc """
  Displays the "next block" being assembled — block N+1 relative to the
  latest confirmed block. Shows that the chain is alive and work is in progress.

  Currently shows the expected height and a visual indicator.
  When mempool polling is available, will also show pending tx count and size.
  """
  use Phoenix.Component

  attr :latest_height, :integer, required: true

  attr :info, :map,
    default: nil,
    doc: "Bitblocks.NextBlock.info/1: state and tx count, when known"

  def next_block(assigns) do
    info = assigns.info || %{state: :unknown, num_tx: nil}

    assigns =
      assigns
      |> assign(:next_height, (assigns.latest_height || 0) + 1)
      |> assign(:state, info.state)
      |> assign(:num_tx, info.num_tx)
      |> assign(:node_blocks, Map.get(info, :node_blocks))
      |> assign(:node_headers, Map.get(info, :node_headers))

    ~H"""
    <div
      id="next-block"
      class="border border-dashed border-gray-300 dark:border-gray-700 rounded py-2 px-3 mb-2"
    >
      <div class="flex items-center justify-between gap-3 font-mono text-xs">
        <div class="flex items-center gap-3">
          <span
            class="w-2 h-2 rounded-full bg-brand-strong motion-safe:animate-pulse"
            aria-hidden="true"
          >
          </span>
          <span class="text-sm text-gray-900 dark:text-white tabular-nums">
            {number(@next_height)}
          </span>
          <span
            :if={is_integer(@num_tx)}
            id="next-block-txs"
            class="text-gray-700 dark:text-gray-300 tabular-nums"
          >
            {number(@num_tx)} {if @state == :assembling, do: "txs waiting", else: "txs"}
          </span>
          <span class="text-gray-600 dark:text-gray-400">
            {label(@state)}
          </span>
          <span
            :if={@state == :node_verifying and is_integer(@node_blocks) and is_integer(@node_headers)}
            id="next-block-node-progress"
            class="text-gray-600 dark:text-gray-400 tabular-nums"
          >
            (verified {number(@node_blocks)} of {number(@node_headers)})
          </span>
        </div>
        <span class="text-gray-600 dark:text-gray-400">
          next block
        </span>
      </div>
    </div>
    """
  end

  defp label(:on_chain), do: "on chain, not stored yet"
  defp label(:node_verifying), do: "on chain · our node is still verifying it"
  defp label(:assembling), do: "assembling…"
  defp label(_), do: "assembling…"

  defp number(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  defp number(n), do: to_string(n)
end
