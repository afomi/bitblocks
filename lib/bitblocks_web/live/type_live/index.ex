defmodule BitblocksWeb.TypeLive.Index do
  @moduledoc """
  `/types`: every transaction type, grouped, each linked to its page.
  The definitions come from `Bitblocks.TxTypes`.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.TxTypes
  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "Transaction types",
         meta_description:
           "A glossary of Bitcoin SV transaction types: payments, inscriptions, tokens, data protocols and contracts, each with its script pattern and real examples.",
         canonical_path: "/types"
       )
     )
     |> assign(:groups, TxTypes.groups())}
  end
end
