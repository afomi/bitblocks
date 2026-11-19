defmodule BitblocksWeb.DownloadLive do
  @moduledoc """
  `/downloads/:id`: a bought download of a block range, for its buyer only
  (https://github.com/afomi/bitblocks/issues/111).

  It says where the purchase stands, and updates by itself as Stripe's
  webhook and the preparing worker move it (`Purchases.topic/1`): "Waiting
  for payment confirmation", "Paid" while the files are prepared and once
  they're ready, "Expired", "Refunded", "Failed", "Checkout expired".

  Once ready: the manifest (every file anchored to its block hash, with its
  sha256), a page of files with links signed on each load (`Purchases.links/3`,
  15 minutes, free while the purchase is valid), the manifest as JSON, and a
  script that downloads every file, checks each sha256, and skips the files
  already there, so running it again resumes. "Resume" re-signs the links
  from the block given.

  A visitor who isn't signed in is sent to sign in and back; anyone but the
  buyer gets a 404.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.Downloads
  alias Bitblocks.Downloads.Purchases
  alias BitblocksWeb.DownloadFileController
  alias BitblocksWeb.UserAuth

  @page_files 100

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:ok, redirect(socket, to: UserAuth.sign_in_path("/downloads/" <> id))}

      user ->
        case Purchases.get_for_user(id, user) do
          nil ->
            raise Ecto.NoResultsError, queryable: Bitblocks.Downloads.Purchase

          purchase ->
            if connected?(socket),
              do: Phoenix.PubSub.subscribe(Bitblocks.PubSub, Purchases.topic(purchase.id))

            {:ok,
             socket
             |> assign(:page_title, "Your download")
             |> assign(:meta_robots, "noindex, nofollow")
             |> assign(:page_from, purchase.from_height)
             |> assign(:links_error, nil)
             |> assign(:base_url, BitblocksWeb.Endpoint.url())
             |> assign_purchase(purchase)}
        end
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns[:purchase] do
      nil ->
        {:noreply, socket}

      purchase ->
        from =
          case Integer.parse(params["from"] || "") do
            {n, ""} -> n |> max(purchase.from_height) |> min(purchase.to_height)
            _ -> purchase.from_height
          end

        {:noreply, socket |> assign(:page_from, from) |> load_files()}
    end
  end

  @impl true
  def handle_event("resume", %{"resume" => %{"from" => from}}, socket) do
    p = socket.assigns.purchase

    case Integer.parse(String.replace(from, [",", "_", " "], "")) do
      {n, ""} when n >= 0 ->
        {:noreply,
         push_patch(socket,
           to: ~p"/downloads/#{p.id}?#{[from: n |> max(p.from_height) |> min(p.to_height)]}"
         )}

      _ ->
        {:noreply, assign(socket, :links_error, "Give the block height to carry on from.")}
    end
  end

  @impl true
  def handle_info({:purchase, purchase}, socket) do
    if purchase.id == socket.assigns.purchase.id do
      {:noreply, socket |> assign_purchase(purchase) |> load_files()}
    else
      {:noreply, socket}
    end
  end

  defp assign_purchase(socket, purchase) do
    state = Purchases.state(purchase)

    socket
    |> assign(:purchase, purchase)
    |> assign(:state, state)
    |> assign(:token, if(state == :ready, do: DownloadFileController.token(purchase.id)))
  end

  # The page of files, each with a fresh signed link while the purchase is
  # valid; otherwise the manifest rows alone.
  defp load_files(socket) do
    p = socket.assigns.purchase
    from = socket.assigns.page_from

    if socket.assigns.state == :ready do
      case Purchases.links(p, from, limit: @page_files, max_bytes: :infinity) do
        {:ok, files} ->
          assign(socket, files: files, links_error: nil)

        {:error, _} ->
          assign(socket,
            files: Purchases.files(p, from, @page_files),
            links_error: "Links are unavailable right now. Reload the page to try again."
          )
      end
    else
      assign(socket, files: [])
    end
  end

  @doc "The heading for a state."
  def state_label(:awaiting_payment), do: "Waiting for payment confirmation"
  def state_label(:preparing), do: "Paid"
  def state_label(:ready), do: "Paid"
  def state_label(:expired), do: "Expired"
  def state_label(:refunded), do: "Refunded"
  def state_label(:failed), do: "Failed"
  def state_label(:checkout_expired), do: "Checkout expired"

  @doc "The price paid or quoted, as dollars."
  def price(purchase),
    do: Downloads.format_usd(Decimal.div(Decimal.new(purchase.price_cents), 100))

  @doc "A date and time, in UTC."
  def format_time(nil), do: ""
  def format_time(%DateTime{} = t), do: Calendar.strftime(t, "%-d %B %Y, %H:%M UTC")

  @doc "The height the next page starts at, or nil on the last page."
  def next_from([], _purchase), do: nil

  def next_from(files, purchase) do
    next = List.last(files).height + 1
    if next <= purchase.to_height, do: next
  end

  @doc "The script that downloads, checks and resumes."
  def script(base_url, purchase, token) do
    """
    #!/usr/bin/env bash
    # Bitblocks download #{purchase.id}
    # Blocks #{purchase.from_height} to #{purchase.to_height}: #{purchase.files} files, #{purchase.bytes} bytes.
    # Saves every file in this directory and checks each against its sha256.
    # Files already here and correct are skipped, so running it again resumes.
    set -euo pipefail
    base="#{base_url}"
    id="#{purchase.id}"
    token="#{token}"
    sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
    next=#{purchase.from_height}
    fails=0
    while :; do
      curl -fsS --retry 5 -o .bitblocks-links.tsv "$base/downloads/$id/links.tsv?from=$next&token=$token"
      [ -s .bitblocks-links.tsv ] || break
      ok=1
      while IFS=$'\\t' read -r height hash bytes sum name url; do
        if [ -f "$name" ] && [ "$(sha "$name")" = "$sum" ]; then next=$((height + 1)); continue; fi
        if curl -fsS --retry 3 -o "$name.part" "$url" && [ "$(sha "$name.part")" = "$sum" ]; then
          mv "$name.part" "$name"; next=$((height + 1))
        else
          ok=0; break
        fi
      done < .bitblocks-links.tsv
      if [ "$ok" = 1 ]; then fails=0; else
        fails=$((fails + 1))
        if [ "$fails" -ge 5 ]; then echo "Stopped at block $next. Run this again to carry on." >&2; exit 1; fi
        sleep 5
      fi
    done
    rm -f .bitblocks-links.tsv
    echo "Done: all #{purchase.files} files are here, and each matches its sha256."
    """
  end

  defdelegate format_number(n), to: Downloads
end
