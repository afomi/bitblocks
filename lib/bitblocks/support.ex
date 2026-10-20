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
    * `received_sats_30d`, `received_sats_total` — paid to `bsv_address` in
      indexed txs (nil without an address)
    * `received_usd_30d` — at the cached spot price (nil without a price)
  """
  def summary do
    config = config()

    costs =
      Enum.map(Keyword.get(config, :monthly_costs, []), fn {item, usd} ->
        %{item: item, usd: usd}
      end)

    address = Keyword.get(config, :bsv_address)
    {total, last_30d} = received(address)

    %{
      costs: costs,
      monthly_target_usd: if(costs != [], do: Enum.sum_by(costs, & &1.usd)),
      sponsor_url: Keyword.get(config, :sponsor_url),
      bsv_address: address,
      received_sats_total: total,
      received_sats_30d: last_30d,
      received_usd_30d: to_usd(last_30d)
    }
  end

  defp config, do: Application.get_env(:bitblocks, :support, [])

  defp received(nil), do: {nil, nil}

  defp received(address) do
    min_height =
      case Chain.get_latest_block() do
        %{height: tip} -> max(tip - @month_of_blocks, 0)
        nil -> 0
      end

    {Chain.received_for_address(address),
     Chain.received_for_address(address, min_height: min_height)}
  end

  defp to_usd(nil), do: nil

  defp to_usd(sats) do
    case Bitblocks.PriceCache.get() do
      %{price: price} when is_number(price) -> Float.round(sats / 100_000_000 * price, 2)
      _ -> nil
    end
  end
end
