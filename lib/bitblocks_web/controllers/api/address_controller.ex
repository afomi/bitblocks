defmodule BitblocksWeb.Api.AddressController do
  @moduledoc """
  Address endpoints.

  `/utxos` and `/balance` are served from local data (spend_index + output_addresses).
  Local data is only as current as the sync state — addresses in un-synced blocks
  will be missing. The response includes a `source: "local"` meta field.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain
  alias BitblocksWeb.Utils.BsvParams

  action_fallback BitblocksWeb.FallbackController

  @doc """
  Get unspent outputs for an address.

  GET /api/v1/addresses/:address/utxos

  Returns UTXOs from the local spend_index + output_addresses index.
  """
  def utxos(conn, %{"address" => address}) do
    with {:ok, valid} <- BsvParams.address(address) do
      utxos = Chain.utxos_for_address(valid)

      json(conn, %{
        data: utxos,
        meta: %{address: valid, count: length(utxos), source: "local"}
      })
    else
      {:error, :invalid_address} ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})
    end
  end

  @doc """
  Get balance for an address.

  GET /api/v1/addresses/:address/balance

  Returns confirmed satoshi balance from local data.
  """
  def balance(conn, %{"address" => address}) do
    with {:ok, valid} <- BsvParams.address(address) do
      satoshis = Chain.balance_for_address(valid)

      json(conn, %{
        data: %{confirmed: satoshis},
        meta: %{address: valid, source: "local"}
      })
    else
      {:error, :invalid_address} ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})
    end
  end
end
