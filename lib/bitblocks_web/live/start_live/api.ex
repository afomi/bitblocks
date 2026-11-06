defmodule BitblocksWeb.StartLive.Api do
  @moduledoc """
  `/start/api`: the developer reference a builder comes back to, for how to call
  the API and which endpoints matter first. The endpoint list is data, so a test
  can hold every row to the router and to the access it states.

  Not published yet, like `/start`.
  """
  use BitblocksWeb, :live_view

  import BitblocksWeb.StartComponents

  alias BitblocksWeb.Seo
  alias BitblocksWeb.StartLive.Index

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "Bitblocks API",
         meta_description: "How to call the Bitblocks API, and the endpoints to start with.",
         canonical_path: "/start/api",
         meta_robots: "noindex, nofollow"
       )
     )
     |> assign(:rate_limits, Index.rate_limits())
     |> assign(:groups, groups())}
  end

  @doc """
  The core endpoints, by what a builder wants. `access` is `:open` (no caller
  needed) or `:caller` (a signed-in session or a key).
  """
  def groups do
    txid = "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"

    [
      %{
        id: "chain",
        title: "Blocks and transactions",
        lede: "The records themselves.",
        rows: [
          row("GET", "/api/v1/status", :open, "Health, and how far the index reaches."),
          row("GET", "/api/v1/blocks/latest", :caller, "The newest block held."),
          row(
            "GET",
            "/api/v1/blocks/:id",
            :caller,
            "A block by height or hash.",
            "/api/v1/blocks/170"
          ),
          row("GET", "/api/v1/blocks", :caller, "Blocks, a page at a time."),
          row("GET", "/api/v1/txs/:txid", :caller, "One transaction.", "/api/v1/txs/#{txid}"),
          row(
            "GET",
            "/api/v1/txs",
            :caller,
            "Transactions, a page at a time; filter with ?protocol= or ?block_hash=."
          ),
          row(
            "GET",
            "/api/v1/txs/:txid/raw",
            :caller,
            "The transaction's exact bytes, checked against its txid."
          ),
          row(
            "GET",
            "/api/v1/stream/blocks",
            :caller,
            "New blocks as they arrive, over server-sent events."
          )
        ]
      },
      %{
        id: "proofs",
        title: "Proofs",
        lede: "Evidence you can check without trusting Bitblocks.",
        rows: [
          row(
            "GET",
            "/api/v1/txs/:txid/proof",
            :caller,
            "A merkle proof: index, siblings and root.",
            "/api/v1/txs/#{txid}/proof"
          ),
          row(
            "GET",
            "/api/v1/txs/:txid/beef",
            :caller,
            "The same proofs as BEEF (BRC-62), for a wallet or an SPV client."
          )
        ]
      },
      %{
        id: "coins",
        title: "Addresses, scripts and outpoints",
        lede: "What an address or a script holds. Read the status on every answer; see below.",
        rows: [
          row(
            "GET",
            "/api/v1/addresses/:address/balance",
            :caller,
            "A balance, with its status."
          ),
          row(
            "GET",
            "/api/v1/addresses/:address/utxos",
            :caller,
            "Known-unspent outputs, and the ones not yet settled."
          ),
          row(
            "GET",
            "/api/v1/script/:scripthash/history",
            :caller,
            "Every transaction touching a script."
          ),
          row(
            "GET",
            "/api/v1/script/:scripthash/unspent",
            :caller,
            "Outputs locked by a script."
          ),
          row("POST", "/api/v1/script/decode", :caller, "Script hex into a typed description."),
          row(
            "GET",
            "/api/v1/outpoints/:txid/:vout",
            :caller,
            "Is this outpoint an ordinal or token? Answers yes, no or unknown."
          )
        ]
      },
      %{
        id: "apps",
        title: "What's on chain",
        lede: "The indexes behind the demos. These are beta, and fill in as the sync climbs.",
        rows: [
          row("GET", "/api/v1/types", :caller, "Transaction types, with their pages and counts."),
          row("GET", "/api/v1/protocols", :caller, "Registered on-chain protocols."),
          row("GET", "/api/v1/tokens", :caller, "BSV-20 and BSV-21 tokens."),
          row(
            "GET",
            "/api/v1/collections/:id",
            :caller,
            "A collection and its verification.",
            "/api/v1/collections/rexxies"
          ),
          row(
            "GET",
            "/api/v1/collections/:id/items",
            :caller,
            "Items in mint order, with owner and trace state.",
            "/api/v1/collections/rexxies/items"
          ),
          row("GET", "/api/v1/bitcom", :caller, "The Bitcom registry, with txids to check."),
          row(
            "GET",
            "/api/v1/metanet/:txid",
            :caller,
            "A Metanet node with its parent and children."
          )
        ]
      }
    ]
  end

  defp row(method, path, access, does, example \\ nil) do
    %{method: method, path: path, access: access, does: does, example: example}
  end

  @doc false
  def envelope_example do
    """
    {
      "data": [ ... ],
      "meta": { "next_cursor": "...", "per_page": 50, "complete": false }
    }
    """
  end

  @doc false
  def unauthorized_example do
    """
    {
      "error": "Sign in at /sign-in, or send an API key as Authorization: Bearer <key>"
    }
    """
  end
end
