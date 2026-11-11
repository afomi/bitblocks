defmodule Bitblocks.Repo.Migrations.AddStatusToSupportBlockScans do
  use Ecto.Migration

  # Support.Scan says why it stops (#74): a block being read, or one that
  # failed, has a row too, and only `read` rows count toward coverage.
  def change do
    alter table(:support_block_scans) do
      # read | reading | failed
      add(:status, :string, null: false, default: "read")
      # The last failure, in words, and how many reads have failed in a row.
      add(:error, :text)
      add(:attempts, :integer, null: false, default: 0)
      add(:started_at, :utc_datetime)
    end
  end
end
