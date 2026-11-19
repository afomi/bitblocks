defmodule Bitblocks.Repo.Migrations.CreateDownloadPurchases do
  @moduledoc """
  Paid bulk downloads (https://github.com/afomi/bitblocks/issues/111):

    * `download_purchases`: one quote a buyer chose to pay for, and its
      purchase. One row is one Stripe Checkout session (the idempotency key
      is the row's id). The price is computed here, from stored sizes, never
      taken from the browser.
    * `stripe_events`: every Stripe webhook event handled, by its event id,
      so a replay or a second delivery changes nothing.
    * `block_object_digests`: the sha256 of a block's object in the tx store
      (`blocks/<height>-<hash>.bin`), computed once when a purchase is
      prepared and kept, since the object is immutable.

  New tables only: nothing on `blocks` or `transactions` changes.
  """
  use Ecto.Migration

  def change do
    create table(:download_purchases, primary_key: false) do
      # A random uuid: it is in the buyer's URL, so it must not be guessable.
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, on_delete: :restrict), null: false)

      # What was quoted: blocks from_height..to_height inclusive, as data and
      # format (Bitblocks.Downloads.data_options/0).
      add(:from_height, :integer, null: false)
      add(:to_height, :integer, null: false)
      add(:data, :text, null: false)
      add(:format, :text, null: false)
      # complete_through when quoted; the range was at or below it.
      add(:complete_through, :integer, null: false)
      add(:files, :integer, null: false)
      # The exact summed blocks.size of the range.
      add(:bytes, :bigint, null: false)
      add(:billable_gib, :decimal, null: false)
      add(:price_usd_per_gib, :decimal, null: false)
      # billable_gib x price_usd_per_gib, in cents: what Checkout charges.
      add(:price_cents, :integer, null: false)
      add(:currency, :text, null: false, default: "usd")

      # quoted -> checkout_open -> paid -> refunded | failed; quoted or
      # checkout_open -> expired when Checkout lapses unpaid.
      add(:status, :text, null: false, default: "quoted")
      # "sandbox" (Stripe test mode) or "live": the key the session was made with.
      add(:stripe_mode, :text, null: false)
      add(:stripe_session_id, :text)
      add(:stripe_checkout_url, :text)
      add(:stripe_payment_intent, :text)
      add(:paid_at, :utc_datetime)
      # paid_at + 30 days: links are issued only before it.
      add(:expires_at, :utc_datetime)
      add(:refunded_at, :utc_datetime)
      # Why a paid purchase was marked failed, in plain words.
      add(:failed_reason, :text)

      # Preparing the files after payment: each object's sha256 known.
      add(:hashed_files, :integer, null: false, default: 0)
      # Set once every file in the range has its sha256.
      add(:ready_at, :utc_datetime)
      # sha256 of the manifest JSON as first served, so it can't change later.
      add(:manifest_sha256, :text)

      timestamps(type: :utc_datetime)
    end

    create(index(:download_purchases, [:user_id]))
    create(unique_index(:download_purchases, [:stripe_session_id]))
    create(unique_index(:download_purchases, [:stripe_payment_intent]))

    create table(:stripe_events, primary_key: false) do
      # Stripe's event id (evt_...): the dedupe key.
      add(:id, :text, primary_key: true)
      add(:type, :text, null: false)
      add(:livemode, :boolean, null: false)
      add(:purchase_id, :binary_id)
      # What handling did: paid, refunded, expired, ignored, or a refusal reason.
      add(:outcome, :text, null: false)
      add(:received_at, :utc_datetime, null: false)
    end

    create table(:block_object_digests, primary_key: false) do
      # The object is blocks/<height>-<hash>.bin; the hash names it.
      add(:block_hash, :text, primary_key: true)
      add(:height, :integer, null: false)
      add(:bytes, :bigint, null: false)
      # Lowercase hex sha256 of the whole object.
      add(:sha256, :text, null: false)
      add(:inserted_at, :utc_datetime, null: false)
    end

    create(index(:block_object_digests, [:height]))
  end
end
