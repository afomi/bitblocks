defmodule BitblocksWeb.Api.AddressController do
  @moduledoc """
  Address endpoints, served from local data (`spend_index` and the raw txs
  tagged with the address in `output_addresses`).

  `/utxos` and `/balance` are exact or say they are not, by the rule in
  `Bitblocks.Chain.Utxos`: an output is unspent only when no stored tx
  spends it and every block through our tip is synced. Each answer has a
  `status` (`exact`, `partial` or `unknown`), `indexed_through_height` and
  `tip_height`, and `source: "local"`.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain.Utxos
  alias BitblocksWeb.Utils.BsvParams

  action_fallback BitblocksWeb.FallbackController

  @doc """
  Unspent outputs for an address.

  GET /api/v1/addresses/:address/utxos

  `data` lists only outputs known to be unspent, so it is empty unless the
  index reaches the tip. `unknown` lists outputs with no recorded spend
  whose spent-ness isn't settled yet; don't spend those on our word.
  """
  def utxos(conn, %{"address" => address}) do
    with {:ok, valid} <- BsvParams.address(address) do
      set = Utxos.for_address(valid)
      unspent = Utxos.with_status(set, :unspent)

      json(conn, %{
        data: unspent,
        unknown: Utxos.with_status(set, :unknown),
        meta: %{
          address: valid,
          count: length(unspent),
          status: set.status,
          indexed_through_height: set.indexed_through_height,
          tip_height: set.tip_height,
          source: "local"
        }
      })
    else
      {:error, :invalid_address} ->
        conn |> put_status(400) |> json(%{error: "Invalid address"})
    end
  end

  @doc """
  Balance for an address.

  GET /api/v1/addresses/:address/balance

  `data` has `status`, `indexed_through_height` and `tip_height`. When
  `status` is `exact` it has `confirmed` (satoshis); otherwise it has
  `unknown` (satoshis in outputs with no recorded spend that may be spent
  in blocks not synced yet) and no `confirmed` key.
  """
  def balance(conn, %{"address" => address}) do
    with {:ok, valid} <- BsvParams.address(address) do
      json(conn, %{
        data: Utxos.balance(valid),
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
