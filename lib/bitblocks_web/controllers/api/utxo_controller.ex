defmodule BitblocksWeb.Api.UtxoController do
  @moduledoc """
  UTXO ownership endpoints.

  Proxied from WhatsOnChain until bitblocks maintains its own UTXO set.
  When a local UTXO index exists (built from output_addresses + input_txids),
  these endpoints can be backed by local data with no external dependency.
  """
  use BitblocksWeb, :controller

  alias BitblocksWeb.Utils.BsvParams

  action_fallback BitblocksWeb.FallbackController

  @woc_base "https://api.whatsonchain.com/v1/bsv/main"

  @doc """
  Returns the current owner address of a specific transaction output,
  and whether it has been spent.

  GET /api/v1/utxo/:txid/:vout/owner

  Response:
    { "address": "1Abc...", "spent": false }
    { "address": "1Abc...", "spent": true, "spent_by": "<txid>" }
    { "address": null, "spent": true }   — OP_RETURN or unrecognized script

  Used by VoteSmash to verify ticket UTXO ownership before building
  presentation (Tx 2) and stamp (Tx 3) transactions.
  """
  def owner(conn, %{"txid" => txid, "vout" => vout_str}) do
    with {:ok, txid} <- BsvParams.txid(txid),
         {:ok, vout} <- parse_vout(vout_str),
         {:ok, address} <- fetch_output_address(txid, vout),
         {:ok, spend_info} <- fetch_spend_info(txid, vout) do
      json(conn, Map.merge(%{address: address}, spend_info))
    else
      {:error, :invalid_txid} ->
        conn |> put_status(400) |> json(%{error: "Invalid txid — must be 64 hex characters"})

      {:error, :invalid_vout} ->
        conn |> put_status(400) |> json(%{error: "Invalid vout — must be a non-negative integer"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Output not found"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: "Upstream error: #{inspect(reason)}"})
    end
  end

  # -- Private ------------------------------------------------------------------

  defp parse_vout(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_vout}
    end
  end

  # Fetch the output address from WoC's tx endpoint.
  defp fetch_output_address(txid, vout) do
    url = "#{@woc_base}/tx/hash/#{URI.encode_www_form(txid)}"

    case woc_get(url) do
      {:ok, %{"vout" => outputs}} when is_list(outputs) ->
        case Enum.at(outputs, vout) do
          nil ->
            {:error, :not_found}

          output ->
            address =
              get_in(output, ["scriptPubKey", "addresses"])
              |> case do
                [addr | _] when is_binary(addr) -> addr
                _ -> nil
              end

            {:ok, address}
        end

      {:ok, _} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  # Fetch spend status from WoC's spend endpoint.
  # Returns %{spent: false} or %{spent: true, spent_by: txid}.
  defp fetch_spend_info(txid, vout) do
    url = "#{@woc_base}/tx/#{URI.encode_www_form(txid)}/out/#{vout}/spend"

    case woc_get(url) do
      {:ok, %{"txid" => spent_txid}} when is_binary(spent_txid) ->
        {:ok, %{spent: true, spent_by: spent_txid}}

      {:ok, _} ->
        {:ok, %{spent: false}}

      # WoC returns 404 for unspent outputs on this endpoint
      {:error, :not_found} ->
        {:ok, %{spent: false}}

      error ->
        error
    end
  end

  defp woc_get(url) do
    case HTTPoison.get(url, [{"Accept", "application/json"}], recv_timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :bad_response}
        end

      {:ok, %{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %{status_code: status}} ->
        {:error, {:upstream_status, status}}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end
end
