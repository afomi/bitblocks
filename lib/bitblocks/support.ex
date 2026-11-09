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
  alias Bitblocks.Support.Recent

  # ~30 days of blocks at 10 minutes each.
  @month_of_blocks 30 * 24 * 6

  @doc "The off-site sponsorship page, or nil when not configured."
  def sponsor_url, do: Keyword.get(config(), :sponsor_url)

  @doc """
  The support summary:

    * `costs` — `[%{item, usd}]`, and `monthly_target_usd` (their sum, or nil
      when no costs are configured)
    * `sponsor_url`, `bsv_address` — nil when not configured
    * `received_sats_30d`, `received_sats_total` — given to `bsv_address`
      (nil without an address): from our index through `complete_through`,
      plus the blocks above it from WhatsOnChain (`Support.Recent`)
    * `received_through_height` — the block both totals are complete
      through: WhatsOnChain's tip when it answered, else `complete_through`
    * `received_sources` — each source with the heights it covers and, for
      WhatsOnChain, `status` ok or unavailable (then its gifts are left out)
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
      received_through_height: received.through_height,
      received_sources: received.sources,
      received_usd_30d: to_usd(received.last_30d)
    }
  end

  defp config, do: Application.get_env(:bitblocks, :support, [])

  defp received(nil), do: %{total: nil, last_30d: nil, through_height: nil, sources: []}

  # Our index through complete_through, where every block is stored, and
  # WhatsOnChain above it, so no block is counted twice or skipped.
  defp received(address) do
    indexed_through = Bitblocks.Sync.complete_through()

    min_height =
      case Chain.get_latest_block() do
        %{height: tip} -> max(tip - @month_of_blocks, 0)
        nil -> 0
      end

    stored = Chain.received_for_address(address, max_height: indexed_through)

    stored_30d =
      Chain.received_for_address(address, min_height: min_height, max_height: indexed_through)

    index = %{source: "index", from_height: 0, through_height: indexed_through}

    case Recent.get(address, indexed_through) do
      {:ok, %{gifts: gifts, through_height: woc_through}} ->
        recent = Enum.sum_by(gifts, & &1.sats)
        recent_30d = gifts |> Enum.filter(&(&1.height >= min_height)) |> Enum.sum_by(& &1.sats)

        %{
          total: stored + recent,
          last_30d: stored_30d + recent_30d,
          through_height: woc_through || indexed_through,
          sources: [index, woc_source("ok", indexed_through, woc_through)]
        }

      {:error, _reason} ->
        %{
          total: stored,
          last_30d: stored_30d,
          through_height: indexed_through,
          sources: [index, woc_source("unavailable", indexed_through, nil)]
        }
    end
  end

  defp woc_source(status, indexed_through, through_height) do
    %{
      source: "whatsonchain",
      from_height: indexed_through + 1,
      through_height: through_height,
      status: status
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
