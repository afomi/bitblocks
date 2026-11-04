defmodule BitblocksWeb.Api.UtxoController do
  @moduledoc """
  UTXO ownership: who an output pays, and whether it is spent.

  Local data first, by the rule in `Bitblocks.Chain.Utxos`: a recorded
  spend is spent, and no recorded spend is unspent only when every block
  through our tip is synced. When the local answer is unknown, or we don't
  hold the tx, WhatsOnChain answers instead (`Bitblocks.Woc`). Every answer
  names its `source` (`local` or `whatsonchain`), so a proxied answer is
  never passed off as ours.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Chain.{RawBlock, RawTx, TxIngest, Utxos}
  alias Bitblocks.Woc
  alias BitblocksWeb.Utils.BsvParams

  action_fallback BitblocksWeb.FallbackController

  @doc """
  The address a transaction output pays, and whether it has been spent.

  GET /api/v1/utxo/:txid/:vout/owner

  Response (`status` is spent, unspent, unspendable or unknown):

      {"address": "1Abc...", "spent": false, "status": "unspent", "source": "local",
       "indexed_through_height": 900000, "tip_height": 900000}
      {"address": "1Abc...", "spent": true, "spent_by": "<txid>", "spent_by_vin": 0,
       "status": "spent", "source": "local", ...}
      {"address": "1Abc...", "spent": false, "status": "unspent", "source": "whatsonchain"}
      {"address": null, "spent": true, "status": "unspendable", "source": "local", ...}
      {"address": "1Abc...", "spent": null, "status": "unknown", "source": "local", ...}

  The last is our own answer when the index isn't synced to the tip and
  WhatsOnChain can't be reached. `address` is read from the output's
  script (P2PKH or P2PK), else null.

  Used by VoteSmash to verify ticket UTXO ownership before building
  presentation (Tx 2) and stamp (Tx 3) transactions.
  """
  def owner(conn, %{"txid" => txid, "vout" => vout_str}) do
    with {:ok, txid} <- BsvParams.txid(txid),
         {:ok, vout} <- parse_vout(vout_str),
         {:ok, answer} <- answer(txid, vout) do
      json(conn, answer)
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

  defp answer(txid, vout) do
    case Utxos.outpoint(txid, vout) do
      {:ok, %{status: :unknown} = local} -> {:ok, woc_spend_or_unknown(local)}
      {:ok, local} -> {:ok, local_answer(local)}
      {:error, _} -> woc_answer(txid, vout)
    end
  end

  defp local_answer(%{status: status} = local) do
    base = %{
      address: local.address,
      status: status,
      source: "local",
      indexed_through_height: local.indexed_through_height,
      tip_height: local.tip_height
    }

    case status do
      :spent ->
        Map.merge(base, %{spent: true, spent_by: local.spent_by, spent_by_vin: local.spent_by_vin})

      :unspent ->
        Map.put(base, :spent, false)

      :unspendable ->
        Map.put(base, :spent, true)

      :unknown ->
        Map.put(base, :spent, nil)
    end
  end

  # We hold the output but can't settle its spent-ness: ask WhatsOnChain,
  # and say so; if it can't answer, our answer is unknown.
  defp woc_spend_or_unknown(local) do
    case woc_spend(local.txid, local.vout) do
      {:ok, spend} -> Map.merge(%{address: local.address, source: "whatsonchain"}, spend)
      {:error, _} -> local_answer(local)
    end
  end

  # We don't hold the tx: WhatsOnChain for both the output and its spend.
  defp woc_answer(txid, vout) do
    with {:ok, address} <- woc_output_address(txid, vout),
         {:ok, spend} <- woc_spend(txid, vout) do
      {:ok, Map.merge(%{address: address, source: "whatsonchain"}, spend)}
    end
  end

  defp woc_output_address(txid, vout) do
    with {:ok, txs} <- Woc.txs([txid]),
         %{"hex" => hex} when is_binary(hex) <- Enum.find(txs, &(&1["txid"] == txid)),
         true <- TxIngest.body_matches_txid?(hex, txid) || {:error, :bad_response},
         {:ok, %{outputs: outputs}} <- RawTx.flows(hex),
         {_sats, script} <- Enum.at(outputs, vout) do
      {:ok, RawBlock.script_address(script)}
    else
      {:error, :invalid_tx} -> {:error, :bad_response}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp woc_spend(txid, vout) do
    case Woc.spent(txid, vout) do
      {:ok, %{txid: by, vin: vin}} ->
        {:ok, %{spent: true, spent_by: by, spent_by_vin: vin, status: :spent}}

      {:ok, :unspent} ->
        {:ok, %{spent: false, status: :unspent}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
