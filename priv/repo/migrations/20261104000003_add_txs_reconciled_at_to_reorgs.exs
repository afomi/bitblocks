defmodule Bitblocks.Repo.Migrations.AddTxsReconciledAtToReorgs do
  use Ecto.Migration

  # #34: when the transaction rows of a reorg's replaced blocks were moved to
  # the blocks that hold them, or removed. Null while rows still point at an
  # orphaned hash. `reorgs` is a handful of rows, so a plain column add.
  def change do
    alter table(:reorgs) do
      add(:txs_reconciled_at, :utc_datetime)
    end
  end
end
