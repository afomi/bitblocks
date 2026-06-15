defmodule BitblocksWeb.Api.AddressController do
  @moduledoc """
  Address endpoints.

  UTXO data is proxied from WhatsOnChain — bitblocks does not maintain
  its own UTXO set. When bitblocks has its own address index, these
  endpoints can be backed by local data instead.
  """
  use BitblocksWeb, :controller

  alias BitblocksWeb.Utils.BsvParams

  action_fallback BitblocksWeb.FallbackController

  @woc_base "https://api.whatsonchain.com/v1/bsv/main"

  @doc """
  Get unspent outputs for an address.

  GET /api/v1/addresses/:address/utxos

  Proxies to WhatsOnChain's UTXO endpoint.
  """
  def utxos(conn, %{"address" => address}) do
    proxy_address(conn, address, fn valid, body ->
      case Jason.decode(body) do
        {:ok, utxos} ->
          json(conn, %{
            data: utxos,
            meta: %{address: valid, count: length(utxos), source: "whatsonchain"}
          })

        {:error, _} ->
          conn |> put_status(502) |> json(%{error: "Bad response from upstream"})
      end
    end)
  end

  @doc """
  Get balance for an address.

  GET /api/v1/addresses/:address/balance

  Proxies to WhatsOnChain's balance endpoint.
  """
  def balance(conn, %{"address" => address}) do
    proxy_address(conn, address, fn valid, body ->
      case Jason.decode(body) do
        {:ok, balance} ->
          json(conn, %{data: balance, meta: %{address: valid, source: "whatsonchain"}})

        {:error, _} ->
          conn |> put_status(502) |> json(%{error: "Bad response from upstream"})
      end
    end)
  end

  # -- Private ------------------------------------------------------------------

  # Validate the address (T7), build the WoC URL with the encoded address, fetch,
  # and hand a 200 body to `on_ok`. The path suffix is derived from the action,
  # so callers can't influence the route shape with a crafted param.
  defp proxy_address(conn, address, on_ok) do
    with {:ok, valid} <- BsvParams.address(address) do
      suffix = if conn.private.phoenix_action == :utxos, do: "unspent", else: "balance"
      url = "#{@woc_base}/address/#{URI.encode_www_form(valid)}/#{suffix}"

      case HTTPoison.get(url, [{"Accept", "application/json"}], recv_timeout: 10_000) do
        {:ok, %{status_code: 200, body: body}} ->
          on_ok.(valid, body)

        {:ok, %{status_code: status}} ->
          conn |> put_status(status) |> json(%{error: "Upstream returned #{status}"})

        {:error, %{reason: reason}} ->
          conn |> put_status(502) |> json(%{error: "Upstream error: #{inspect(reason)}"})
      end
    else
      {:error, :invalid_address} ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})
    end
  end
end
