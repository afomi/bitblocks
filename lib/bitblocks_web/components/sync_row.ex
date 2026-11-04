defmodule BitblocksWeb.SyncRow do
  @moduledoc """
  One sync block in one row: height, tx count, downloaded x of y with a thin
  bar, and its stage. The compact take on a row of `BitblocksWeb.SyncTable`
  (/syncing), for /blocks. Both read `Bitblocks.SyncProgress.snapshot().sync`
  and never query.
  """
  use Phoenix.Component

  import BitblocksWeb.SyncTable, only: [number: 1, worker_text: 1]

  @doc "The rows a worker holds right now (slot assigned), in height order."
  def working(nil), do: []

  def working(%{rows: rows}) when is_list(rows),
    do: rows |> Enum.filter(&is_integer(&1[:slot])) |> Enum.sort_by(& &1.height)

  def working(_), do: []

  @doc "The working rows by height, for marking those blocks in the list below."
  def working_by_height(sync), do: sync |> working() |> Map.new(&{&1.height, &1})

  @doc """
  The loading fill behind a block's own row in the /blocks list: the row's
  background sweeps from 0 to 100% as its txs are downloaded, with a bright
  leading edge and, where motion is allowed, a shimmer. It is the first child
  of a `relative` row whose content blocks are `relative` too, so the content
  paints above it.
  """
  attr :row, :map, required: true

  def block_progress_fill(assigns) do
    assigns = assign(assigns, :pct, pct(assigns.row))

    ~H"""
    <span
      class="absolute inset-0 overflow-hidden"
      role="progressbar"
      aria-label={"Block #{@row.height} transactions loaded"}
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@pct}
    >
      <span
        class="block-progress-fill absolute inset-y-0 left-0 border-r-2 border-brand bg-gradient-to-r from-brand/5 to-brand/15 dark:from-brand/10 dark:to-brand/25 motion-safe:transition-[width] motion-safe:duration-700 motion-safe:ease-out"
        style={"width: #{@pct}%"}
      >
      </span>
    </span>
    """
  end

  @doc "The x of y label beside a loading block's tx count, with its percent."
  attr :row, :map, required: true

  def block_progress_label(assigns) do
    assigns = assign(assigns, :pct, pct(assigns.row))

    ~H"""
    <span
      id={"block-progress-#{@row.height}"}
      class="font-mono text-xs text-brand-strong dark:text-brand tabular-nums"
    >
      {number(@row[:fetched] || 0)} of {number(@row.num_tx)} loaded · {@pct}%
    </span>
    """
  end

  attr :row, :map, required: true

  def sync_row(assigns) do
    assigns = assign(assigns, :pct, pct(assigns.row))

    ~H"""
    <a
      id={"sync-row-#{@row.height}"}
      href={"/blocks/#{@row.height}"}
      class="flex items-center gap-3 rounded border border-dashed border-gray-300 dark:border-gray-700 px-3 py-1.5 font-mono text-xs text-gray-700 dark:text-gray-300 hover:border-gray-500"
    >
      <span
        class="w-2 h-2 rounded-full bg-brand-strong motion-safe:animate-pulse"
        aria-hidden="true"
      >
      </span>
      <span class="tabular-nums text-gray-900 dark:text-white">
        {number(@row.height)}
      </span>
      <span class="tabular-nums">
        {number(@row[:fetched] || 0)} of {number(@row.num_tx)} txs
      </span>
      <span
        class="flex-1 h-1 rounded bg-gray-200 dark:bg-gray-700 overflow-hidden"
        role="progressbar"
        aria-label={"Block #{@row.height} downloaded"}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={@pct}
      >
        <span
          class="block h-full bg-brand-strong dark:bg-brand"
          style={"width: #{@pct}%"}
        >
        </span>
      </span>
      <span class="text-gray-600 dark:text-gray-400">
        {worker_text(@row)}
      </span>
    </a>
    """
  end

  defp pct(%{num_tx: n} = row) when is_integer(n) and n > 0,
    do: min(round((row[:fetched] || 0) * 100 / n), 100)

  defp pct(_), do: 0
end
