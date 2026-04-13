defmodule BitblocksWeb.NextBlockComponent do
  @moduledoc """
  Displays the "next block" being assembled — block N+1 relative to the
  latest confirmed block. Shows that the chain is alive and work is in progress.

  Currently shows the expected height and a visual indicator.
  When mempool polling is available, will also show pending tx count and size.
  """
  use Phoenix.Component

  attr :latest_height, :integer, required: true

  def next_block(assigns) do
    assigns = assign(assigns, :next_height, (assigns.latest_height || 0) + 1)

    ~H"""
    <div class="border border-dashed border-neutral-700 rounded py-4 px-5 mb-2">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <span class="w-2 h-2 rounded-full bg-brand animate-pulse"></span>
          <span class="font-mono text-sm text-neutral-50 tabular-nums">
            {@next_height}
          </span>
          <span class="font-mono text-xs text-neutral-500">
            assembling…
          </span>
        </div>
        <span class="font-mono text-xs text-neutral-500">
          next block
        </span>
      </div>
    </div>
    """
  end
end
