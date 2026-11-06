defmodule BitblocksWeb.SyncingLive do
  @moduledoc """
  The one sync page, for signed-in readers: how far it is complete ("Complete
  through block X, of N known"), the board of blocks being fetched, and the
  overall picture (tips, header coverage, blocks by sync_state). Admins also
  get the operator panel: pause, worker slots, failed blocks, the audit.

  The board is one list in height order. A block that finishes stays where
  it is, marked verified, for #{45} seconds, then fades over 15 and leaves
  (`board/3`), so finishing reads as a change of state, not a jump to
  another list.

  Every number comes from `Bitblocks.SyncProgress`, one snapshot shared by
  every viewer and pushed at most once a second, so for a reader this view
  never queries. The operator panel reads its own, for admins only, on a
  timer. Every operator event checks `admin?` on the server, because the page
  itself is open to any signed-in user.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.{Ops, Release, Sync, SyncProgress}

  embed_templates "syncing_live/*"

  @operator_refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: SyncProgress.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Syncing", audit: nil, audit_running: false)
     |> assign_snapshot(SyncProgress.snapshot())
     |> assign_operator()
     |> schedule_operator_refresh()}
  end

  # A durable pause (#44): no new block jobs while paused, across restarts and
  # deploys; blocks already dispatched finish.
  @impl true
  def handle_event("set_paused", %{"paused" => value}, %{assigns: %{admin?: true}} = socket) do
    {:ok, paused} = Sync.set_paused(value == "true")

    message =
      if paused,
        do: "Paused: no new blocks are dispatched; blocks in progress finish.",
        else: "Resumed: the loop dispatches the lowest incomplete blocks again."

    {:noreply, socket |> put_flash(:info, message) |> assign_operator()}
  end

  # Clamped server-side to the computed limit; the coordinator applies it on
  # its next tick.
  def handle_event(
        "set_concurrency",
        %{"concurrency" => value},
        %{assigns: %{admin?: true}} = socket
      ) do
    case Integer.parse(to_string(value)) do
      {n, ""} ->
        {:ok, applied} = Sync.set_concurrency(n)

        message =
          if applied == n,
            do: "Concurrency set to #{applied}.",
            else:
              "Concurrency set to #{applied}: the most this node allows is #{socket.assigns.limit_max}."

        {:noreply, socket |> assign_operator() |> put_flash(:info, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "Concurrency must be a whole number.")}
    end
  end

  def handle_event("run_audit", _params, %{assigns: %{admin?: true}} = socket) do
    {:noreply,
     socket
     |> assign(audit_running: true)
     |> start_async(:audit, fn -> Release.audit_completeness(limit: 50) end)}
  end

  def handle_event("repair_incomplete", _params, %{assigns: %{admin?: true}} = socket) do
    {:noreply,
     socket
     |> assign(audit_running: true)
     |> start_async(:repair, fn -> Release.repair_incomplete_blocks() end)}
  end

  def handle_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "That's for admins.")}
  end

  @impl true
  def handle_async(:audit, {:ok, result}, socket) do
    {:noreply, assign(socket, audit: result, audit_running: false)}
  end

  def handle_async(:audit, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(audit_running: false)
     |> put_flash(:error, "Audit failed: #{inspect(reason)}")}
  end

  def handle_async(:repair, {:ok, {:ok, %{reset: reset}}}, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       "Repair: reopened #{reset} block(s); the sync loop refills them in order"
     )
     |> start_async(:audit, fn -> Release.audit_completeness(limit: 50) end)
     |> assign_operator()}
  end

  def handle_async(:repair, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(audit_running: false)
     |> put_flash(:error, "Repair failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:sync_snapshot, snapshot}, socket) do
    {:noreply, assign_snapshot(socket, snapshot)}
  end

  def handle_info(:refresh_operator, socket) do
    {:noreply, socket |> assign_operator() |> schedule_operator_refresh()}
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

  defp assign_operator(%{assigns: %{admin?: true}} = socket) do
    {limit_max, limit_reason} = Sync.concurrency_limit()

    assign(socket,
      health: Ops.health(),
      paused: Sync.paused?(),
      still_finishing: length(Sync.live_jobs()),
      failed_blocks: Sync.failed_blocks(),
      webhook_failures: Bitblocks.Projections.webhook_failures(),
      concurrency: Sync.concurrency(),
      limit_max: limit_max,
      limit_reason: limit_reason
    )
  end

  defp assign_operator(socket), do: socket

  defp schedule_operator_refresh(%{assigns: %{admin?: true}} = socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_operator, @operator_refresh_ms)
    socket
  end

  defp schedule_operator_refresh(socket), do: socket

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
