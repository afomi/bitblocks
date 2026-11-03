defmodule Bitblocks.Repo.Migrations.IndexBlocksUpdatedAt do
  use Ecto.Migration

  # The incremental chain-tile build (#48) asks "which blocks changed since
  # the last build?" every few minutes. Without this index that is a
  # sequential scan of `blocks` (~1M wide rows) each time. Concurrent, so tip
  # sync keeps writing while it builds (AGENTS.md, migrations on large tables).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(index(:blocks, [:updated_at], concurrently: true))
  end
end
