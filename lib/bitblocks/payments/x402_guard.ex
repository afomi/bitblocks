defmodule Bitblocks.Payments.X402Guard do
  @moduledoc """
  The x402 replay guard (`X402.ReplayGuard`) on the `x402_payments` table.

  A claim is one insert behind the unique index on `key`: of two requests
  carrying the same signed authorization, on any node, exactly one inserts and
  goes on to settle; the other is `:replayed`. Any error refuses the payment
  before money moves, so a database outage fails closed. Rows are never
  deleted. This is x402_ex v0.1.0's README guard, on our table.
  """
  @behaviour X402.ReplayGuard

  import Ecto.Query

  require Logger

  alias Bitblocks.Repo

  @table "x402_payments"

  @impl true
  def claim(key, meta, _config) do
    row = %{
      key: key,
      kind: Atom.to_string(meta.kind),
      app: meta.app,
      network: meta.network,
      asset: meta.asset,
      pay_to: meta.pay_to,
      payer: meta.payer,
      amount: meta.amount,
      resource: meta.resource,
      tx_hash: meta.tx_hash,
      auth_key: meta.auth_key,
      dispute: meta.dispute && Atom.to_string(meta.dispute),
      inserted_at: DateTime.utc_now()
    }

    case Repo.insert_all(@table, [row], on_conflict: :nothing, conflict_target: [:key]) do
      {1, _} -> :ok
      {0, _} -> {:error, :replayed}
    end
  rescue
    e ->
      Logger.error("x402 claim failed: #{inspect(e.__struct__)}")
      {:error, :unavailable}
  end

  @impl true
  def record_payment_intent(tx_key, payment_intent_id, _config) do
    case Repo.update_all(from(c in @table, where: c.key == ^tx_key),
           set: [payment_intent_id: payment_intent_id]
         ) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("x402 record_payment_intent failed: #{inspect(e.__struct__)}")
      {:error, :unavailable}
  end

  @impl true
  def unrecorded(limit, _config) do
    rows =
      Repo.all(
        from c in @table,
          where: c.kind == "transaction" and is_nil(c.payment_intent_id),
          order_by: c.inserted_at,
          limit: ^limit,
          select: %{
            key: c.key,
            tx_hash: c.tx_hash,
            network: c.network,
            asset: c.asset,
            amount: c.amount
          }
      )

    {:ok, rows}
  rescue
    e ->
      Logger.error("x402 unrecorded failed: #{inspect(e.__struct__)}")
      {:error, :unavailable}
  end
end
