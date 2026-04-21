defmodule Bitblocks.Repo.Migrations.AddTxidPrefixIndex do
  use Ecto.Migration

  # B-tree index with text_pattern_ops supports prefix LIKE queries (e.g. "abc%")
  # without needing a full trigram index. The existing unique_index on txid uses
  # default ops and cannot be used by ILIKE prefix searches.
  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS transactions_txid_prefix_idx
    ON transactions (txid text_pattern_ops);
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS transactions_txid_prefix_idx;")
  end
end
