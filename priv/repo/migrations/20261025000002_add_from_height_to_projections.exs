defmodule Bitblocks.Repo.Migrations.AddFromHeightToProjections do
  use Ecto.Migration

  # #29 step 3, status.
  #
  # from_height — the first block a projection covers. Bitblocks holds tx data
  #               for part of the chain, so a projection is complete over
  #               [from_height, tip], not from genesis: a donation address
  #               created in 2026 needs nothing older.
  # status      — now the operator's intent only: active | paused. Whether the
  #               index is ready or backfilling is computed from block sync
  #               state (Projections.status/1), never stored, so it can't go
  #               stale.
  def up do
    alter table(:projections) do
      add(:from_height, :integer, null: false, default: 0)
      modify(:status, :string, null: false, default: "active")
    end

    execute("UPDATE projections SET status = 'active' WHERE status IN ('backfilling', 'ready')")
  end

  def down do
    execute("UPDATE projections SET status = 'backfilling' WHERE status = 'active'")

    alter table(:projections) do
      remove(:from_height)
      modify(:status, :string, null: false, default: "backfilling")
    end
  end
end
