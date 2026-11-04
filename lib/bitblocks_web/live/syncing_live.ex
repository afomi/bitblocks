defmodule BitblocksWeb.SyncingLive do
  @moduledoc """
  Public, read-only, live view of the sync: how far it is complete ("Complete
  through block X, of N known"), the blocks being fetched with synced and
  processed counts, the recently completed blocks, and the overall picture
  (tips, header coverage, blocks by sync_state).

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
     |> assign(:snapshot, SyncProgress.snapshot())}
  end

  @impl true
  def handle_info({:sync_snapshot, snapshot}, socket) do
    {:noreply, assign(socket, :snapshot, snapshot)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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
