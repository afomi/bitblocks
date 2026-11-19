defmodule Bitblocks.Downloads.Purchase do
  @moduledoc """
  One bought (or being bought) download of a block range
  (https://github.com/afomi/bitblocks/issues/111). See
  `Bitblocks.Downloads.Purchases` for the life of a row.

  Status: `quoted` -> `checkout_open` -> `paid` -> `refunded` | `failed`;
  `quoted` or `checkout_open` -> `expired` when Checkout lapses unpaid.
  A paid purchase's links end at `expires_at` (30 days after payment) with
  no change of status.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(quoted checkout_open paid refunded failed expired)

  schema "download_purchases" do
    belongs_to :user, Bitblocks.Accounts.User, type: :id

    field :from_height, :integer
    field :to_height, :integer
    field :data, :string
    field :format, :string
    field :complete_through, :integer
    field :files, :integer
    field :bytes, :integer
    field :billable_gib, :decimal
    field :price_usd_per_gib, :decimal
    field :price_cents, :integer
    field :currency, :string, default: "usd"

    field :status, :string, default: "quoted"
    field :stripe_mode, :string
    field :stripe_session_id, :string
    field :stripe_checkout_url, :string
    field :stripe_payment_intent, :string
    field :paid_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :refunded_at, :utc_datetime
    field :failed_reason, :string

    field :hashed_files, :integer, default: 0
    field :ready_at, :utc_datetime
    field :manifest_sha256, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Every status a purchase can hold."
  def statuses, do: @statuses
end
