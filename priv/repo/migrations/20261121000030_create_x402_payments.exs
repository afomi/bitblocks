defmodule Bitblocks.Repo.Migrations.CreateX402Payments do
  @moduledoc """
  The x402 replay guard's claims (`Bitblocks.Payments.X402Guard`): one row per
  claimed authorization and one per settled transaction, never deleted.

  The shape is x402_ex v0.1.0's README migration. Its two indexes are the only
  ones: the unique index on `key` is what makes a claim atomic across requests
  and nodes, and the partial index serves the reconciler's one query. The
  README's plain indexes on `tx_hash` and `auth_key` are left out; nothing here
  queries by them, and the table stays small (one row per paid request).
  """
  use Ecto.Migration

  def change do
    create table(:x402_payments) do
      # "auth:<payment id>" before settling, "tx:<network>:<tx hash>" after.
      add(:key, :text, null: false)
      # "authorization", "transaction", or "transaction_disputed" (a settle that
      # reported success but contradicted the signed payment).
      add(:kind, :text, null: false)
      # On "transaction_disputed" rows: "payer_mismatch" or "amount_mismatch".
      add(:dispute, :text)
      # The app this claim belongs to (the :scope app name, "bitblocks").
      add(:app, :text, null: false)
      # CAIP-2, e.g. "eip155:84532" (Base Sepolia).
      add(:network, :text, null: false)
      # The token contract (USDC).
      add(:asset, :text, null: false)
      # Our deposit address.
      add(:pay_to, :text, null: false)
      add(:payer, :text)
      # Atomic token units, as a string (10000 = 0.01 USDC).
      add(:amount, :text, null: false)
      # The URL the payment was for.
      add(:resource, :text, null: false)
      # On "transaction" rows: the on-chain hash (also Stripe's idempotency key),
      # the "auth:" key it settled, and the Stripe PaymentIntent once recorded.
      add(:tx_hash, :text)
      add(:auth_key, :text)
      add(:payment_intent_id, :text)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:x402_payments, [:key]))

    # The reconciler's query: settled, not yet in Stripe.
    create(
      index(:x402_payments, [:inserted_at],
        where: "kind = 'transaction' AND payment_intent_id IS NULL",
        name: :x402_payments_unrecorded_index
      )
    )
  end
end
