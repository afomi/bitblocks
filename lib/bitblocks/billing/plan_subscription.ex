defmodule Bitblocks.Billing.PlanSubscription do
  @moduledoc """
  One Checkout a user started for a monthly plan, and the Stripe subscription
  it became (`Bitblocks.Billing`). It keeps the plan's limits as chosen.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "plan_subscriptions" do
    belongs_to :user, Bitblocks.Accounts.User

    field :plan_id, :string
    field :plan_name, :string
    field :stripe_price_id, :string
    field :price_cents, :integer
    field :currency, :string, default: "usd"
    field :requests_per_minute, :integer
    field :monthly_requests, :integer
    field :monthly_gib, :integer

    field :status, :string, default: "checkout_open"
    field :stripe_mode, :string
    field :stripe_session_id, :string
    field :stripe_checkout_url, :string
    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string
    field :stripe_status, :string
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime
    field :cancel_at_period_end, :boolean, default: false
    field :canceled_at, :utc_datetime
    field :last_event_created, :integer

    timestamps(type: :utc_datetime)
  end
end
