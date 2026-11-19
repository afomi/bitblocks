defmodule Bitblocks.Repo.Migrations.CreatePlanSubscriptions do
  @moduledoc """
  Monthly plans (https://github.com/afomi/bitblocks/issues/112):

    * `plan_subscriptions`: one row per Checkout a signed-in user started for
      a plan, and the Stripe subscription it became. The row keeps a copy of
      the plan's limits as they were when chosen, so a later change to the
      plans' config never moves a subscriber's limit by itself.
    * `stripe_events.plan_subscription_id`: which row an event changed, as
      `purchase_id` does for a download.

  New table and one nullable column: nothing on `blocks` or `transactions` changes.
  """
  use Ecto.Migration

  def change do
    create table(:plan_subscriptions, primary_key: false) do
      # A random uuid: it is the Checkout session's client_reference_id and
      # idempotency key.
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, on_delete: :restrict), null: false)

      # The plan chosen (Bitblocks.Billing.plans/0), and its terms then.
      add(:plan_id, :text, null: false)
      add(:plan_name, :text, null: false)
      add(:stripe_price_id, :text, null: false)
      add(:price_cents, :integer, null: false)
      add(:currency, :text, null: false, default: "usd")
      add(:requests_per_minute, :integer, null: false)
      add(:monthly_requests, :bigint, null: false)
      add(:monthly_gib, :integer, null: false)

      # checkout_open -> subscribed, or checkout_open -> expired when the
      # Checkout lapses unpaid.
      add(:status, :text, null: false, default: "checkout_open")
      # "sandbox" or "live": the key the Checkout was made with.
      add(:stripe_mode, :text, null: false)
      add(:stripe_session_id, :text)
      add(:stripe_checkout_url, :text)
      add(:stripe_customer_id, :text)
      add(:stripe_subscription_id, :text)
      # The subscription's own status, as Stripe last told us: active,
      # past_due, canceled, unpaid, incomplete, ...
      add(:stripe_status, :text)
      add(:current_period_start, :utc_datetime)
      add(:current_period_end, :utc_datetime)
      add(:cancel_at_period_end, :boolean, null: false, default: false)
      add(:canceled_at, :utc_datetime)
      # The `created` (unix seconds) of the newest event applied, so an
      # older event arriving late changes nothing.
      add(:last_event_created, :bigint)

      timestamps(type: :utc_datetime)
    end

    create(index(:plan_subscriptions, [:user_id]))
    create(unique_index(:plan_subscriptions, [:stripe_subscription_id]))

    alter table(:stripe_events) do
      add(:plan_subscription_id, :binary_id)
    end
  end
end
