defmodule BitblocksWeb.BitcomLive do
  @moduledoc """
  A live Bitcom registry (unwriter's Bitcom, 2019): `/bitcom` lists every
  namespace bitblocks knows, and `/bitcom/:address` is that address's home —
  owner proof, files, routes, and real usage from the index.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.Bitcom
  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"address" => address}, _uri, socket) do
    socket =
      if Bitcom.address?(address) do
        entry = Bitcom.entry(address)

        socket
        |> assign(
          Seo.public_page(
            page_title: "#{entry.name} · Bitcom",
            meta_description:
              "Bitcom namespace #{address}: ownership proof, files, routes, and usage.",
            canonical_path: "/bitcom/#{address}"
          )
        )
        |> assign(
          view: :home,
          entry: entry,
          files: Bitcom.files(address),
          routes: Bitcom.routes(address),
          history: Bitcom.history(address),
          recent: Bitcom.recent_transactions(address)
        )
      else
        socket
        |> assign(Seo.public_page(page_title: "Bitcom", meta_robots: "noindex"))
        |> assign(view: :not_found, address: address)
      end

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> assign(
        Seo.public_page(
          page_title: "Bitcom Registry",
          meta_description:
            "A live Bitcom registry: every Bitcoin application protocol namespace, its on-chain ownership proof, files, routes, and usage.",
          canonical_path: "/bitcom"
        )
      )
      |> assign(view: :directory, entries: Bitcom.directory())

    {:noreply, socket}
  end

  defp tier_label(:proven), do: "proven"
  defp tier_label(:self_described), do: "self-described"
  defp tier_label(:listed), do: "listed"

  defp tier_class(:proven), do: "bg-green-100 text-green-800"
  defp tier_class(:self_described), do: "bg-blue-100 text-blue-800"
  defp tier_class(:listed), do: "bg-gray-100 text-gray-800"

  defp usage_label(usage) do
    if usage >= Bitcom.usage_cap(),
      do: "#{delimit(usage)}+",
      else: delimit(usage)
  end

  defp delimit(n),
    do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  defp short(txid) when is_binary(txid), do: String.slice(txid, 0, 12) <> "…"
  defp short(_), do: ""

  # bit://<address>/<txid> → the txid, when the source is a tx in the index.
  defp locator_txid("bit://" <> rest) do
    case String.split(rest, "/") do
      [_address, txid] -> if txid =~ ~r/\A[0-9a-f]{64}\z/, do: txid
      _ -> nil
    end
  end

  defp locator_txid(_), do: nil
end
