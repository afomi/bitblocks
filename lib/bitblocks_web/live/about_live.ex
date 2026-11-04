defmodule BitblocksWeb.AboutLive do
  @moduledoc """
  /about: what Bitblocks is and how it is built, with the live numbers each
  layer stands behind and the command and endpoint behind each page.

  The numbers come from the shared sync snapshot (`Bitblocks.SyncProgress`),
  an ETS read, and follow its once-a-second broadcast; the page never queries.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.SyncProgress
  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: SyncProgress.subscribe()

    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "About Bitblocks",
         meta_description:
           "Bitblocks is a thin web layer over a Bitcoin SV node, a Postgres database and command-line tools. Every page reads records you can fetch from the API.",
         canonical_path: "/about"
       )
     )
     |> assign(:coverage, SyncProgress.snapshot().overview)}
  end

  @impl true
  def handle_info({:sync_snapshot, snapshot}, socket) do
    {:noreply, assign(socket, :coverage, snapshot.overview)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @doc "The layers, bottom up: what each is, and the live fact it stands behind."
  def layers(coverage) do
    [
      %{
        id: "layer-node",
        name: "Node",
        body:
          "A Bitcoin SV node, read over RPC and REST. Every block and transaction here comes from it.",
        fact: count_fact("Node tip", coverage.node_tip)
      },
      %{
        id: "layer-records",
        name: "Records",
        body:
          "Postgres holds every block and transaction as fetched, and each derived value carries the version of the step that computed it.",
        fact: count_fact("Headers stored", coverage.headers_stored)
      },
      %{
        id: "layer-sync",
        name: "Sync",
        body:
          "One loop works upward from genesis, one block at a time, and rebuilds each block's merkle root before calling it complete.",
        fact: count_fact("Complete through block", complete_through(coverage))
      },
      %{
        id: "layer-commands",
        name: "Commands",
        body:
          "Every operation is a command an operator can run and read the result of. After an outage the sync resumes by itself.",
        fact: nil
      },
      %{
        id: "layer-web",
        name: "Pages and API",
        body:
          "The pages and the API read the same records. A page is a view of them, never the only way in.",
        fact: nil
      }
    ]
  end

  @doc "What sits behind a page: its API endpoint and the operator's command."
  def sources do
    [
      {"/syncing", "GET /api/v1/status", "Bitblocks.Release.sync_status()"},
      {"/blocks", "GET /api/v1/blocks", "Bitblocks.Release.gaps()"},
      {"/status", "GET /api/v1/status", "Bitblocks.Release.status()"},
      {"/reorgs", nil, ~s|Bitblocks.Release.reconcile_orphaned_block("<hash>")|},
      {nil, "GET /api/v1/status/derivations", "Bitblocks.Release.derivation_runs()"}
    ]
  end

  defp complete_through(%{complete_through: h}) when is_integer(h) and h >= 0, do: h
  defp complete_through(_), do: nil

  defp count_fact(_label, nil), do: nil
  defp count_fact(label, n), do: {label, BitblocksWeb.Sats.delimit(n)}
end
