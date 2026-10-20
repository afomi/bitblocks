defmodule BitblocksWeb.Api.OutpointController do
  @moduledoc """
  Outpoint classification for wallets that fail closed.

  `GET /api/v1/outpoints/:txid/:vout` answers whether an outpoint is an
  ordinal or token with `"yes"`, `"no"`, or `"unknown"` — see
  `Bitblocks.Outpoints`. A wallet should spend only on `"no"`.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Outpoints
  alias BitblocksWeb.Utils.BsvParams

  def show(conn, %{"txid" => txid, "vout" => vout}) do
    with {:ok, txid} <- BsvParams.txid(txid),
         {vout, ""} when vout >= 0 <- Integer.parse(vout) do
      case Outpoints.classify(txid, vout) do
        {:error, :vout_out_of_range} ->
          conn |> put_status(404) |> json(%{error: "Output index out of range"})

        answer ->
          json(conn, %{data: Map.merge(%{txid: txid, vout: vout}, render_answer(answer))})
      end
    else
      {:error, :invalid_txid} -> conn |> put_status(400) |> json(%{error: "Invalid txid"})
      _ -> conn |> put_status(400) |> json(%{error: "Invalid vout"})
    end
  end

  defp render_answer({:yes, kind, reason}), do: %{answer: "yes", kind: kind, reason: reason}
  defp render_answer({:no, reason}), do: %{answer: "no", kind: nil, reason: reason}
  defp render_answer({:unknown, reason}), do: %{answer: "unknown", kind: nil, reason: reason}
end
