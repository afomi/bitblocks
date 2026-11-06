defmodule BitblocksWeb.TypeLive.Index do
  @moduledoc """
  `/types`: every transaction type, grouped, each linked to its page, with
  how many transactions have it and the first block it was seen in.
  The definitions come from `Bitblocks.TxTypes`; the counts from the cache
  in `Bitblocks.TxTypes.Counts`, so a page view runs no query.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.TxTypes
  alias Bitblocks.TxTypes.Counts
  alias BitblocksWeb.Seo

  import BitblocksWeb.Sats, only: [delimit: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "Bitcoin transaction types",
         meta_description:
           "A glossary of Bitcoin transaction types: payments, inscriptions, tokens, data protocols and contracts, each with its script pattern and real examples.",
         canonical_path: "/types"
       )
     )
     |> assign(:groups, TxTypes.groups())
     |> assign(:counts, Counts.get())}
  end

  defp count(counts, type), do: Counts.count(counts, type.id)

  defp txs(1), do: "1 tx"
  defp txs(n), do: "#{delimit(n)} txs"
end
