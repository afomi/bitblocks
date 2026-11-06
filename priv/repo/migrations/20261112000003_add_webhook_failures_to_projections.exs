defmodule Bitblocks.Repo.Migrations.AddWebhookFailuresToProjections do
  use Ecto.Migration

  # A webhook delivery that ran out of retries, or was refused (#29). Oban
  # prunes discarded jobs within a minute, so the record lives here, and
  # /syncing lists it for admins. Setting the webhook again clears it.
  #
  # webhook_failures      — deliveries given up on since the webhook was set.
  # webhook_failed_at     — when the latest one was given up on.
  # webhook_failed_event  — its event: tx or reorg.
  # webhook_failed_status — why: the last HTTP status or transport error.
  def change do
    alter table(:projections) do
      add(:webhook_failures, :integer, null: false, default: 0)
      add(:webhook_failed_at, :utc_datetime)
      add(:webhook_failed_event, :string)
      add(:webhook_failed_status, :string)
    end
  end
end
