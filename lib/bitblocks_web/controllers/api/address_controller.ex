defmodule BitblocksWeb.Api.AddressController do
  @moduledoc """
  Address endpoints.

  UTXO data is proxied from WhatsOnChain — bitblocks does not maintain
  its own UTXO set. When bitblocks has its own address index, these
  endpoints can be backed by local data instead.
  """
  use BitblocksWeb, :controller

  action_fallback BitblocksWeb.FallbackController

  @woc_base "https://api.whatsonchain.com/v1/bsv/main"

  @doc """
  Get unspent outputs for an address.

  GET /api/v1/addresses/:address/utxos

  Proxies to WhatsOnChain's UTXO endpoint.
  """
  def utxos(conn, %{"address" => address}) do
    url = "#{@woc_base}/address/#{address}/unspent"

    case HTTPoison.get(url, [{"Accept", "application/json"}], recv_timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, utxos} ->
            json(conn, %{
              data: utxos,
              meta: %{address: address, count: length(utxos), source: "whatsonchain"}
            })

          {:error, _} ->
            conn |> put_status(502) |> json(%{error: "Bad response from upstream"})
        end

      {:ok, %{status_code: status}} ->
        conn |> put_status(status) |> json(%{error: "Upstream returned #{status}"})

      {:error, %{reason: reason}} ->
        conn |> put_status(502) |> json(%{error: "Upstream error: #{inspect(reason)}"})
    end
  end

  @doc """
  Get balance for an address.

  GET /api/v1/addresses/:address/balance

  Proxies to WhatsOnChain's balance endpoint.
  """
  def balance(conn, %{"address" => address}) do
    url = "#{@woc_base}/address/#{address}/balance"

    case HTTPoison.get(url, [{"Accept", "application/json"}], recv_timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, balance} ->
            json(conn, %{
              data: balance,
              meta: %{address: address, source: "whatsonchain"}
            })

          {:error, _} ->
            conn |> put_status(502) |> json(%{error: "Bad response from upstream"})
        end

      {:ok, %{status_code: status}} ->
        conn |> put_status(status) |> json(%{error: "Upstream returned #{status}"})

      {:error, %{reason: reason}} ->
        conn |> put_status(502) |> json(%{error: "Upstream error: #{inspect(reason)}"})
    end
  end
end
