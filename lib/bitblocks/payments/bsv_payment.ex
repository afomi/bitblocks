defmodule Bitblocks.Payments.BsvPayment do
  @moduledoc """
  One BSV payment taken for one request (`Bitblocks.Payments.Bsv402`): the
  `bsv_payments` row, unique on `txid`, the replay guard.

  `status` starts `accepted` (our node took the transaction into its
  mempool). `Bitblocks.Payments.Bsv402.Confirmation`, run each minute by
  `Bitblocks.Workers.BsvPaymentWorker`, moves it on: `confirmed` (in a block
  our headers hold, `block_hash` and `block_height` set), `settled` (that
  block `settle_depth` deep), `dropped` (not mined in time) or `conflicted`
  (an input spent by another transaction). A reorg moves `confirmed` back to
  `accepted`. Dropped and conflicted rows are the deny list.
  """
  use Ecto.Schema

  schema "bsv_payments" do
    field :txid, :string
    field :vout, :integer
    field :satoshis, :integer
    field :sender_key, :string
    field :derivation_prefix, :string
    field :derivation_suffix, :string
    field :raw_tx, :binary
    field :request_hash, :string
    field :envelope, :string, default: "brc121"
    field :price_sats, :integer
    field :status, :string, default: "accepted"
    field :block_hash, :string
    field :block_height, :integer
    field :caller, :string
    field :accepted_at, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    field :reason, :string
    field :checks, :integer, default: 0
    field :checked_at, :utc_datetime_usec
    field :next_check_at, :utc_datetime_usec
    field :rebroadcast_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
