defmodule Bitblocks.Repo.Migrations.AddTraceErrorToCollectionItems do
  use Ecto.Migration

  # #46: a failed trace no longer overwrites what an item's last good trace
  # found. The failure is recorded beside it instead, so a later run retries.
  #
  # trace_error      — why the last trace attempt failed (e.g. WhatsOnChain
  #                    answered 500); null once a trace answers.
  # trace_checked_at — when a trace last ran, answered or not. traced_at still
  #                    dates the last answer.
  #
  # trace_state gains `ended` (a final, settled state: the item's trail truly
  # ends, e.g. a Run jig spent outside Run). The column is unconstrained, so
  # that needs no change here.
  def change do
    alter table(:collection_items) do
      add(:trace_error, :text)
      add(:trace_checked_at, :utc_datetime)
    end
  end
end
