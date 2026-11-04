defmodule Bitblocks.TransactionsStatsSettingsTest do
  # Infra, 2026-11-03: `transactions` (~10M rows) had not been auto-analyzed
  # since 2026-07-10, so the planner scanned the table and tx_store_check timed
  # out. At the default scale factor of 0.1, autoanalyze waits for ~1M changed
  # rows. The table-level thresholds live with the schema, so they survive a
  # restore.
  use Bitblocks.DataCase, async: true

  test "transactions is analyzed and vacuumed on table-level thresholds" do
    %{rows: [[options]]} =
      Bitblocks.Repo.query!("SELECT reloptions FROM pg_class WHERE relname = 'transactions'")

    options = options || []

    assert "autovacuum_analyze_scale_factor=0.01" in options
    assert "autovacuum_analyze_threshold=1000" in options
    assert "autovacuum_vacuum_scale_factor=0.02" in options
  end
end
