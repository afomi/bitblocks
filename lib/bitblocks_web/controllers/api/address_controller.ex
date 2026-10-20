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

  @doc """
  Unspent BSV-20/21 token outputs held by an address — the wallet-basket view
  (BRC-163 basket `bsv21`).

  GET /api/v1/addresses/:address/tokens?standard=bsv-21&token_id=<txid>_<vout>
  """
  def tokens(conn, %{"address" => address} = params) do
    with {:ok, valid} <- BsvParams.address(address),
         {:ok, standard} <- standard_param(params["standard"]),
         {:ok, token_id} <- token_id_param(params["token_id"]) do
      outputs = Bitblocks.Tokens.unspent_outputs(valid, standard: standard, token_id: token_id)

      json(conn, %{
        data: outputs,
        meta: %{address: valid, count: length(outputs), source: "local"}
      })
    else
      {:error, :invalid_address} -> conn |> put_status(400) |> json(%{error: "Invalid address"})
      {:error, :invalid_standard} -> conn |> put_status(400) |> json(%{error: "Invalid standard"})
      {:error, :invalid_token_id} -> conn |> put_status(400) |> json(%{error: "Invalid token_id"})
    end
  end

  defp standard_param(nil), do: {:ok, nil}
  defp standard_param(standard) when standard in ["bsv-20", "bsv-21"], do: {:ok, standard}
  defp standard_param(_), do: {:error, :invalid_standard}

  defp token_id_param(nil), do: {:ok, nil}
  defp token_id_param(token_id), do: BsvParams.token_id(token_id)
end
