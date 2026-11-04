defmodule Bitblocks.Repo.Migrations.TuneTransactionsAutovacuum do
  use Ecto.Migration

  # `transactions` holds ~10M rows and grows by bulk imports. At Postgres's
  # default autovacuum_analyze_scale_factor (0.1) autoanalyze waits for ~1M
  # changed rows, so on 2026-11-02 its stats were four months stale and the
  # planner chose a full scan (tx_store_check timed out until a manual ANALYZE).
  #
  # Table-level settings: analyze after 1% + 1,000 changed rows (~100k today),
  # vacuum after 2%. ALTER TABLE ... SET takes a brief SHARE UPDATE EXCLUSIVE
  # lock and rewrites nothing, so it is safe on the live table. The settings
  # live here, with the schema, so they survive a restore.
  def change do
    execute(
      """
      ALTER TABLE transactions SET (
        autovacuum_analyze_scale_factor = 0.01,
        autovacuum_analyze_threshold = 1000,
        autovacuum_vacuum_scale_factor = 0.02
      )
      """,
      """
      ALTER TABLE transactions RESET (
        autovacuum_analyze_scale_factor,
        autovacuum_analyze_threshold,
        autovacuum_vacuum_scale_factor
      )
      """
    )
  end
end
