defmodule Bitblocks.Repo.Migrations.AddTxSizeAndRawInDb do
  use Ecto.Migration

  # What a tx weighs, and whether we keep its bytes in the row
  # (docs/TX_STORAGE.md):
  #
  #   transactions.size_bytes  the tx's size in bytes, from its raw bytes. A
  #                            fact about the tx: no version, and it never
  #                            changes. nil until Release.backfill_tx_sizes/1
  #                            reaches an older row.
  #   transactions.raw_in_db   true while the full raw bytes sit in this row.
  #                            Above Transaction.raw_in_db_max_bytes/0 the
  #                            bytes move to the tx store, which keeps every
  #                            tx whatever the threshold, and this turns false.
  #
  # Nullable with no default, so Postgres records the columns in the catalog
  # and rewrites nothing: safe on the large transactions table. The index for
  # the big txs comes in a later migration, after the backfill, so that
  # backfill doesn't pay for it on every row (AGENTS.md, "Migrations on large
  # tables").
  def change do
    execute("SET LOCAL lock_timeout = '10s'", "")

    alter table(:transactions) do
      add(:size_bytes, :bigint)
      add(:raw_in_db, :boolean)
    end
  end
end
