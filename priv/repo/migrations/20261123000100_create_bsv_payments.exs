defmodule Bitblocks.Repo.Migrations.CreateBsvPayments do
  @moduledoc """
  `bsv_payments`: one row per BSV payment taken for a request past a shared
  budget (BRC-121, `Bitblocks.Payments.Bsv402`, docs/BSV_402.md).

  The unique `txid` is the replay guard: of two requests carrying the same
  payment, on any node, exactly one inserts. A row is written once and moved
  only forward; a payment our node refuses is deleted before anything is
  served, so a row always stands for a request we served.
  """
  use Ecto.Migration

  def change do
    create table(:bsv_payments) do
      # The payment's txid, display hex: the replay guard.
      add(:txid, :text, null: false)
      # The output we took, and what it held.
      add(:vout, :integer, null: false)
      add(:satoshis, :bigint, null: false)
      # The payer's identity key, compressed hex.
      add(:sender_key, :text, null: false)
      # BRC-29's remittance, exactly as sent: with our identity key they are
      # what spends the output.
      add(:derivation_prefix, :text, null: false)
      add(:derivation_suffix, :text, null: false)
      # The payment's bytes; the BEEF's ancestry is not kept once checked.
      add(:raw_tx, :binary, null: false)
      # SHA-256 of method, path and query, hex: what was bought.
      add(:request_hash, :text, null: false)
      # brc121 (the x-bsv-* headers) or x402 (a later slice).
      add(:envelope, :text, null: false, default: "brc121")
      # The price when it was taken, so a later change doesn't rewrite history.
      add(:price_sats, :bigint, null: false)
      # accepted, then confirmed, settled, dropped or conflicted (a later slice).
      add(:status, :text, null: false, default: "accepted")
      add(:block_hash, :text)
      add(:block_height, :integer)
      # The usage meter's caller id: the sender key (caller kind "bsv").
      add(:caller, :text, null: false)
      add(:accepted_at, :utc_datetime_usec, null: false)
      add(:confirmed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:bsv_payments, [:txid]))
  end
end
