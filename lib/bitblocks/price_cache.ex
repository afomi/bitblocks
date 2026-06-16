defmodule Bitblocks.PriceCache do
  @moduledoc """
  Caches the BSV spot price fetched from CoinGecko.

  CoinGecko's free API is aggressively rate-limited (~10-30 calls/min), so we
  fetch on an interval and serve every reader from an ETS cache rather than
  calling CoinGecko per request. A refresh runs every `@refresh_interval`; the
  cached value is also returned (as stale) if a refresh fails, so a CoinGecko
  outage degrades to a slightly old price rather than an error.

  Read with `get/0`. Returns `nil` until the first successful fetch.
  """
  use GenServer
  require Logger

  @table __MODULE__
  @refresh_interval :timer.minutes(5)
  # CoinGecko id for Bitcoin SV.
  @coin_id "bitcoin-cash-sv"
  @vs_currencies "usd"
  @url "https://api.coingecko.com/api/v3/simple/price?ids=#{@coin_id}&vs_currencies=#{@vs_currencies}&include_last_updated_at=true&include_24hr_change=true"

  # -- Client API --------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached price map, or `nil` if no successful fetch has happened yet.

  Shape:

      %{
        currency: "usd",
        price: 48.12,
        change_24h: -1.3,
        source: "coingecko",
        fetched_at: ~U[...],          # when we fetched it
        coin_updated_at: ~U[...]      # CoinGecko's own last-updated timestamp
      }
  """
  def get do
    case :ets.lookup(@table, :bsv) do
      [{:bsv, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Forces an immediate refresh (async). Mostly for tests/ops."
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  # -- Server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    # Fetch shortly after boot (don't block startup on an external call).
    Process.send_after(self(), :refresh, 0)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    do_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    do_refresh()
    schedule_refresh()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internal ----------------------------------------------------------------

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)

  defp do_refresh do
    case fetch_price() do
      {:ok, value} ->
        :ets.insert(@table, {:bsv, value})
        Logger.debug("PriceCache: BSV #{value.price} #{value.currency}")

      {:error, reason} ->
        # Keep serving the previous (stale) value; just log.
        Logger.warning("PriceCache: refresh failed (#{inspect(reason)}); keeping cached value")
    end
  rescue
    error ->
      Logger.error("PriceCache: refresh crashed — #{inspect(error)}")
  end

  defp fetch_price do
    case HTTPoison.get(@url, [{"Accept", "application/json"}], timeout: 10_000, recv_timeout: 10_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        parse(body)

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_status, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp parse(body) do
    with {:ok, json} <- Jason.decode(body),
         %{} = coin <- Map.get(json, @coin_id),
         price when is_number(price) <- Map.get(coin, @vs_currencies) do
      {:ok,
       %{
         currency: @vs_currencies,
         price: price,
         change_24h: Map.get(coin, "#{@vs_currencies}_24h_change"),
         source: "coingecko",
         fetched_at: DateTime.utc_now(),
         coin_updated_at: unix_to_datetime(Map.get(coin, "last_updated_at"))
       }}
    else
      _ -> {:error, :unexpected_response}
    end
  end

  defp unix_to_datetime(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
  defp unix_to_datetime(_), do: nil
end
