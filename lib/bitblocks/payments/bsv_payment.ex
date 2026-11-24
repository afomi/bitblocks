defmodule Bitblocks.Payments.BsvPayment do
  @moduledoc """
  One BSV payment taken for one request (`Bitblocks.Payments.Bsv402`): the
  `bsv_payments` row, unique on `txid`, the replay guard.

  `status` starts `accepted` (our node took the transaction into its
  mempool). `confirmed`, `settled`, `dropped` and `conflicted` belong to the
  confirmation worker, a later slice of docs/BSV_402.md.
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

    timestamps(type: :utc_datetime_usec)
  end
end
