defmodule BitblocksWeb.TypeLive.Index do
  @moduledoc """
  `/types`: every transaction type, grouped, each linked to its page, with
  how many transactions have it and the first block it was seen in, plus
  the layers they sit on and the protocol registry.
  The definitions come from `Bitblocks.TxTypes`; the counts from the cache
  in `Bitblocks.TxTypes.Counts`; the registry from `Bitblocks.ProtocolRegistry`.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.TxTypes
  alias Bitblocks.TxTypes.Counts
  alias BitblocksWeb.Seo

  import BitblocksWeb.Sats, only: [delimit: 1]

  @protocols_shown 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "Bitcoin transaction types",
         meta_description:
           "A glossary of Bitcoin transaction types: payments, inscriptions, tokens, data protocols and contracts, each with its script pattern and real examples, plus the registered on-chain protocols.",
         canonical_path: "/types"
       )
     )
     |> assign(:groups, TxTypes.groups())
     |> assign(:counts, Counts.get())
     |> assign(:protocols, ProtocolRegistry.list_protocols(limit: @protocols_shown))
     |> assign(:protocol_count, ProtocolRegistry.count_protocols())}
  end

  defp count(counts, type), do: Counts.count(counts, type.id)

  defp txs(1), do: "1 tx"
  defp txs(n), do: "#{delimit(n)} txs"

  defp layers do
    [
      %{
        level: 4,
        title: "Application protocols",
        summary: "Data protocols and applications, named by an address in their data.",
        href: "#protocols",
        here: true
      },
      %{
        level: 3,
        title: "Transactions",
        summary: "Inputs, outputs, scripts and signatures, typed by what each output does.",
        href: "#transactions",
        here: true
      },
      %{
        level: 2,
        title: "Blocks",
        summary: "Block header, merkle tree, timestamp and difficulty.",
        href: "/blocks",
        here: false
      },
      %{
        level: 1,
        title: "Blockchain",
        summary: "The ledger, proof of work and the chain of blocks.",
        href: nil,
        here: false
      }
    ]
  end

  defp category(category) do
    category |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  # "Proven" is earned on chain, by the rule /bitcom uses. Without a proof a
  # seeded :verified is curation (docs/BITCOM.md), so it reads "Curated".
  defp trust_label(%{ownership_proof_txid: txid}) when is_binary(txid), do: "Proven"

  defp trust_label(%{verification_status: status}) do
    case status do
      :unverified -> "Unverified"
      :pending -> "Pending"
      :beta -> "Beta"
      :verified -> "Curated"
      :deprecated -> "Deprecated"
      _ -> "Unknown"
    end
  end

  defp trust_title(%{ownership_proof_txid: txid}) when is_binary(txid),
    do: "This address proved ownership on chain with a useradd it funded itself."

  defp trust_title(%{verification_status: :verified}),
    do: "Reviewed and listed by hand. No on-chain proof yet."

  defp trust_title(_protocol), do: nil
end
