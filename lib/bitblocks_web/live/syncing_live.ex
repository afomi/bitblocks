defmodule BitblocksWeb.SyncingLive do
  @moduledoc """
  Public, read-only, live view of the sync: how far it is complete ("Complete
  through block X, of N known"), the board of blocks being fetched, and the
  overall picture (tips, header coverage, blocks by sync_state).

  The board is one list in height order. A block that finishes stays where
  it is, marked verified, for #{45} seconds, then fades over 15 and leaves
  (`board/3`), so finishing reads as a change of state, not a jump to
  another list.

  Every number comes from `Bitblocks.SyncProgress`, one snapshot shared by
  every viewer and pushed at most once a second. This view never queries.
  `/sync` is the operator page.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.SyncProgress
  alias BitblocksWeb.Seo

  embed_templates "syncing_live/*"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: SyncProgress.subscribe()

    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "Syncing",
         meta_description:
           "Watch Bitblocks sync Bitcoin SV live: each block's transactions stored and processed, from genesis up.",
         canonical_path: "/syncing"
       )
     )
     |> assign_snapshot(SyncProgress.snapshot())}
  end

  @impl true
  def handle_info({:sync_snapshot, snapshot}, socket) do
    {:noreply, assign_snapshot(socket, snapshot)}
  end

  # Fading rows need a frame each second even when no snapshot arrives.
  def handle_info(:tick, socket) do
    {:noreply, assign_snapshot(socket |> assign(:ticking, false), socket.assigns.snapshot)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @hold_seconds 45
  @fade_seconds 15

  @doc """
  The board: blocks being fetched plus blocks that finished in the last
  #{@hold_seconds + @fade_seconds} seconds, one list, lowest height first.
  Each entry gains `finished` and `opacity` (1.0 while held, then down to 0
  across the fade).
  """
  def board(syncing, recent, now \\ DateTime.utc_now()) do
    working = Enum.map(syncing, &Map.merge(&1, %{finished: false, opacity: 1.0}))
    working_hashes = MapSet.new(working, & &1.hash)

    finished =
      for entry <- recent,
          not MapSet.member?(working_hashes, entry.hash),
          %DateTime{} = at <- [entry[:tx_sync_completed_at]],
          age = DateTime.diff(now, at),
          age < @hold_seconds + @fade_seconds do
        opacity =
          if age <= @hold_seconds,
            do: 1.0,
            else: Float.round(1 - (age - @hold_seconds) / @fade_seconds, 2)

        Map.merge(entry, %{finished: true, opacity: max(opacity, 0.05)})
      end

    Enum.sort_by(working ++ finished, & &1.height)
  end

  defp assign_snapshot(socket, snapshot) do
    board = board(snapshot.syncing, snapshot.recent)

    socket =
      if connected?(socket) and Enum.any?(board, & &1.finished) and
           socket.assigns[:ticking] != true do
        Process.send_after(self(), :tick, 1_000)
        assign(socket, :ticking, true)
      else
        socket
      end

    socket |> assign(:snapshot, snapshot) |> assign(:board, board)
  end

  # -- Formatting --------------------------------------------------------------

  @doc false
  def number(nil), do: "—"

  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc false
  def x_of_y(x, y), do: "#{number(x)} of #{number(y)}"

  @doc false
  def percent(_x, y) when y in [nil, 0], do: 0
  def percent(nil, _y), do: 0
  def percent(x, y), do: min(100, Float.round(x / y * 100, 1))

  @doc false
  def state_label("txs_syncing"), do: "Fetching transactions"
  def state_label("txs_queued"), do: "Queued"
  def state_label("completed"), do: "Completed"
  def state_label("header_only"), do: "Header stored"
  def state_label("header_synced"), do: "Header and txid list stored"
  def state_label("failed"), do: "Failed, will retry"
  def state_label("pending"), do: "Pending"
  def state_label(other), do: other

  @doc false
  def block_time(nil), do: nil
  def block_time(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

  @doc false
  def time_text(nil), do: "time unknown"
  def time_text(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  @doc false
  def behind(nil, _), do: nil
  def behind(_, nil), do: nil
  def behind(ours, theirs), do: max(theirs - ours, 0)
end
