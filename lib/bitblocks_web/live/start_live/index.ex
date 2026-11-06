defmodule BitblocksWeb.StartLive.Index do
  @moduledoc """
  `/start`: the way in for someone building on Bitcoin. What to do first,
  second and third, each step with a real example, then what's been built,
  where to start from, and how to write with Qart.

  Not published yet: no sitemap entry, nav link or home link, and `noindex`
  (see `docs/DEMOS_CAMPAIGN.md`). Figures are read from the sync snapshot and
  the collections index when the page loads, never written into the copy.
  """
  use BitblocksWeb, :live_view

  import BitblocksWeb.CollectionComponents, only: [item_art: 1]
  import BitblocksWeb.StartComponents

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.SyncProgress
  alias BitblocksWeb.{Seo, UserAuth}

  @base_url "https://bitblocks.app"

  # The first spend: block 170, checked against the chain.
  @example_txid "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"
  @example_block_hash "00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee"
  @example_sibling "b1fea52486ce0c62bb442b530a3f0132b826c74e473d1f2c220bfa78111c5082"
  @example_merkleroot "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff"

  @rexxies_shown 6

  @impl true
  def mount(_params, _session, socket) do
    seo =
      Seo.public_page(
        page_title: "Start building on Bitcoin",
        meta_description:
          "Read blocks and transactions, check a proof yourself, and find real work to build on.",
        canonical_path: "/start",
        meta_robots: "noindex, nofollow"
      )

    rexxies = OrdinalCollections.get_collection("rexxies")

    {:ok,
     socket
     |> assign(seo)
     |> assign(:coverage, coverage(SyncProgress.snapshot().overview))
     |> assign(:rexxies, rexxies)
     |> assign(:rexxie_items, rexxie_items(rexxies))
     |> assign(:tardinians, OrdinalCollections.get_collection("grand-tardinians"))
     |> assign(:sign_in_path, UserAuth.sign_in_path("/start"))
     |> assign(:example_txid, @example_txid)
     |> assign(:rate_limits, rate_limits())}
  end

  defp rexxie_items(nil), do: []

  defp rexxie_items(%{id: id}) do
    OrdinalCollections.list_items(id, limit: @rexxies_shown).items
  end

  @doc false
  # Where the sync stands, or nil before it has a figure to give.
  def coverage(%{complete_through: through, our_tip: tip})
      when is_integer(through) and through >= 0 and is_integer(tip) and tip > 0 do
    %{through: through, tip: tip, percent: min(through / tip * 100, 100)}
  end

  def coverage(_overview), do: nil

  @doc "Requests per minute, as the rate limiter is configured."
  def rate_limits do
    config = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, [])

    %{
      anonymous: Keyword.get(config, :max_requests, 30),
      signed_in: Keyword.get(config, :signed_in_max_requests, 600)
    }
  end

  @doc false
  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "The first request, as a newcomer can run it today."
  def curl_status, do: "curl #{@base_url}/api/v1/status"

  @doc false
  def status_example(coverage) do
    {through, tip} =
      case coverage do
        %{through: through, tip: tip} -> {through, tip}
        nil -> {"null", "null"}
      end

    """
    {
      "status": "ok",
      "index": { "complete_through": #{through}, "tip": #{tip} }
    }
    """
  end

  @doc "The example transaction's address on the API."
  def tx_path, do: "/api/v1/txs/#{@example_txid}"

  @doc "The example proof's address on the API."
  def proof_path, do: "/api/v1/txs/#{@example_txid}/proof"

  @doc false
  def tx_example do
    """
    {
      "data": {
        "txid": "#{@example_txid}",
        "block_hash": "#{@example_block_hash}",
        "block_height": 170,
        "version": 1,
        "input_count": 1,
        "output_count": 2,
        "total_output_satoshis": 5000000000
      }
    }
    """
  end

  @doc false
  def proof_example do
    """
    {
      "data": {
        "txid": "#{@example_txid}",
        "index": 1,
        "siblings": [
          "#{@example_sibling}"
        ],
        "merkleroot": "#{@example_merkleroot}",
        "block_hash": "#{@example_block_hash}",
        "block_height": 170
      }
    }
    """
  end

  @doc false
  def proof_check do
    """
    from hashlib import sha256

    def sha256d(b): return sha256(sha256(b).digest()).digest()
    def internal(x): return bytes.fromhex(x)[::-1]

    txid = "#{@example_txid}"
    index = 1
    siblings = ["#{@example_sibling}"]
    merkleroot = "#{@example_merkleroot}"

    node = internal(txid)
    for sibling in siblings:
        pair = node + internal(sibling) if index % 2 == 0 else internal(sibling) + node
        node = sha256d(pair)
        index //= 2

    print(node[::-1].hex() == merkleroot)  # True
    """
  end

  @doc false
  def key_example do
    """
    curl -H "Authorization: Bearer bbk_..." \\
      #{@base_url}#{proof_path()}
    """
  end

  @doc false
  def qart_button do
    """
    <script
      src="https://qart.app/js/qart-checkout.js"
      data-merchant="your-shop"
      data-endpoint="https://qart.app"
      data-api-key="qcpk_..."
    ></script>

    <div
      data-qart-checkout
      data-item-name="Your item"
      data-price-sats="100000"
    >
      <button data-qart-buy>
        Buy
      </button>
    </div>
    """
  end

  @doc false
  def proof_parts, do: {@example_txid, 1, [@example_sibling], @example_merkleroot}

  @doc "The topics `/start/guidance` covers, as `{anchor, title, one line}`."
  def guidance_topics do
    [
      {"standards", "Standards", "Implement a published standard before inventing a format."},
      {"identity", "Identity", "Your identity is the first object you own."},
      {"wallets", "Wallets", "A website should not hold your keys."},
      {"experiences", "Experiences", "Say what you know, and as of when."},
      {"applications", "Applications", "Build the app as a view of the chain."},
      {"resources", "Resources", "Read the spec, then the code, then the summary."},
      {"interesting", "Things we find interesting",
       "What has caught our eye around the ecosystem."}
    ]
  end
end
