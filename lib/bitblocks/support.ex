defmodule Bitblocks.Support do
  @moduledoc """
  What it costs to run bitblocks and how much has come in.

  The sponsorship ask lives off-site (`sponsor_url`); bitblocks only serves
  the numbers, at `GET /api/v1/support`, so that page can show them live.
  Costs and links come from `config :bitblocks, :support` (see
  config/config.exs); nothing is estimated. BSV donations are read from
  bitblocks' own index, so the numbers double as proof the explorer works.
  """

  alias Bitblocks.Chain

  # ~30 days of blocks at 10 minutes each.
  @month_of_blocks 30 * 24 * 6

  @doc "The off-site sponsorship page, or nil when not configured."
  def sponsor_url, do: Keyword.get(config(), :sponsor_url)

  @doc """
  The support summary:

    * `costs` — `[%{item, usd}]`, and `monthly_target_usd` (their sum, or nil
      when no costs are configured)
    * `sponsor_url`, `bsv_address` — nil when not configured
    * `received_sats_total` — given to `bsv_address` (nil without an
      address), from our own index through `complete_through`
    * `received_sats_30d` — the same over the last 30 days, or nil with
      `received_30d_reason` while the index doesn't reach into that window
    * `received_through_height` — the block the totals are complete through
    * `received_pending_from_height` — the first block not counted yet, and
      `received_note`, a sentence saying so
    * `received_sources` — the one source, our index, with its heights
    * `received_usd_30d` — at the cached spot price (nil without a price)
  """
  def summary do
    config = config()

    costs =
      Enum.map(Keyword.get(config, :monthly_costs, []), fn {item, usd} ->
        %{item: item, usd: usd}
      end)

    address = Keyword.get(config, :bsv_address)
    received = received(address)

    %{
      costs: costs,
      monthly_target_usd: if(costs != [], do: Enum.sum_by(costs, & &1.usd)),
      sponsor_url: Keyword.get(config, :sponsor_url),
      bsv_address: address,
      received_sats_total: received.total,
      received_sats_30d: received.last_30d,
      received_30d_reason: received.last_30d_reason,
      received_through_height: received.through_height,
      received_pending_from_height: received.pending_from_height,
      received_note: received.note,
      received_sources: received.sources,
      received_usd_30d: to_usd(received.last_30d)
    }
  end

  defp config, do: Application.get_env(:bitblocks, :support, [])

  defp received(nil),
    do: %{
      total: nil,
      last_30d: nil,
      last_30d_reason: nil,
      through_height: nil,
      pending_from_height: nil,
      note: nil,
      sources: []
    }

  # Our own index only, through complete_through, where every block is
  # stored (#74, option 2: no third-party history). A gift in a newer block
  # counts once the sync reaches it, and the summary says where that starts.
  defp received(address) do
    indexed_through = Bitblocks.Sync.complete_through()

    min_height =
      case Chain.get_latest_block() do
        %{height: tip} -> max(tip - @month_of_blocks, 0)
        nil -> 0
      end

    total = Chain.received_for_address(address, max_height: indexed_through)

    # The 30-day window is only an answer once the index reaches into it;
    # below that a 0 would read as "no gifts", so it is nil with a reason.
    {last_30d, last_30d_reason} =
      if indexed_through >= min_height do
        {Chain.received_for_address(address, min_height: min_height, max_height: indexed_through),
         nil}
      else
        {nil,
         "The last 30 days start at block #{min_height}, and the index is complete through block #{indexed_through}."}
      end

    %{
      total: total,
      last_30d: last_30d,
      last_30d_reason: last_30d_reason,
      through_height: indexed_through,
      pending_from_height: indexed_through + 1,
      note:
        "Counted from our own index through block #{indexed_through}. Gifts in later blocks count once the sync reaches them.",
      sources: [%{source: "index", from_height: 0, through_height: indexed_through}]
    }
  end

  defp to_usd(nil), do: nil

  defp to_usd(sats) do
    case Bitblocks.PriceCache.get() do
      %{price: price} when is_number(price) -> Float.round(sats / 100_000_000 * price, 2)
      _ -> nil
    end
  end
end
