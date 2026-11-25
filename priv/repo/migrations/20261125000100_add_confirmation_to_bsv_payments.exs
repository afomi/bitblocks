defmodule Bitblocks.Repo.Migrations.AddConfirmationToBsvPayments do
  @moduledoc """
  What `Bitblocks.Workers.BsvPaymentWorker` keeps while it follows each
  accepted BSV 402 payment to settled, dropped or conflicted
  (docs/BSV_402.md, slice 4).

  `bsv_payments` is small (one row per paid request), so its indexes are
  plain ones.
  """
  use Ecto.Migration

  def change do
    alter table(:bsv_payments) do
      # Why a payment is dropped or conflicted, in our words or the node's.
      add(:reason, :text)
      # How often the worker has asked our node, and when it next will:
      # the backoff between checks.
      add(:checks, :integer, null: false, default: 0)
      add(:checked_at, :utc_datetime_usec)
      add(:next_check_at, :utc_datetime_usec)
      # The one rebroadcast a payment our node no longer knows gets.
      add(:rebroadcast_at, :utc_datetime_usec)
      # When it became settled, dropped or conflicted. A dropped or
      # conflicted row's sender is refused until closed_at plus the deny
      # period: the deny list is these rows.
      add(:closed_at, :utc_datetime_usec)
    end

    # The worker's pick: rows still open, the most overdue first.
    create(index(:bsv_payments, [:status, :next_check_at]))
    # The verifier's deny-list check, by sender.
    create(index(:bsv_payments, [:sender_key]))
  end
end
