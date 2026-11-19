defmodule Bitblocks.Payments.StripeEvent do
  @moduledoc """
  A Stripe webhook event we handled, by its id: the dedupe record that makes
  a replayed or twice-delivered event change nothing.
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "stripe_events" do
    field :type, :string
    field :livemode, :boolean
    field :purchase_id, :binary_id
    field :plan_subscription_id, :binary_id
    field :outcome, :string
    field :received_at, :utc_datetime
  end
end
