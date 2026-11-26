defmodule Bitblocks.DB.GinPending do
  @moduledoc """
  Keeps the GIN indexes' pending lists short, off the insert path (#87).

  Every GIN index on `transactions` runs with `fastupdate` on, so a new
  row's entries go to a pending list first. When a list passes
  `gin_pending_list_limit` (4 MB by default), the insert that crosses it
  merges the whole list into the index before it returns. On the three
  large indexes (`input_txids`, `output_addresses`, `output_script_hashes`,
  each over 10 GB) that merge ran past the insert's 50 s statement timeout
  about 140 times a day, and each cancel left a tx for the block's retry.

  `run/0` calls `gin_clean_pending_list/1` on each of them, so the merge
  happens here, a minute's worth at a time, instead of inside a sync insert.
  An insert that crosses the limit while this runs finds the cleanup lock
  taken and returns at once, rather than waiting. It changes no data: it
  moves entries the index already holds from its pending list into its
  main tree, the same work autovacuum and the inserts do.
  """

  require Logger

  alias Bitblocks.Repo

  @statement_timeout_ms 600_000

  @doc "The GIN indexes on `table`, by name."
  @spec indexes(String.t()) :: [String.t()]
  def indexes(table \\ "transactions") do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_am a ON a.oid = c.relam
        WHERE i.indrelid = $1::text::regclass AND a.amname = 'gin'
        ORDER BY c.relname
        """,
        [table]
      )

    Enum.map(rows, fn [name] -> name end)
  end

  @doc """
  Cleans each GIN index's pending list. Returns `{index, pages}` per index,
  the pages each cleanup moved, or `{index, {:error, message}}` for one that
  failed; one failure never stops the rest.
  """
  @spec run(String.t()) :: [{String.t(), non_neg_integer() | {:error, String.t()}}]
  def run(table \\ "transactions") do
    for index <- indexes(table) do
      {index, clean(index)}
    end
  end

  defp clean(index) do
    started = System.monotonic_time(:millisecond)

    result =
      Repo.transaction(
        fn ->
          # Named for pg_stat_activity and Performance Insights, this transaction only.
          Repo.query!(
            "SELECT set_config('statement_timeout', $1, true), " <>
              "set_config('application_name', 'bitblocks-gin_pending', true)",
            [
              Integer.to_string(@statement_timeout_ms)
            ]
          )

          %{rows: [[pages]]} =
            Repo.query!("SELECT gin_clean_pending_list($1::text::regclass)", [index],
              telemetry_options: [expected_slow: true]
            )

          pages
        end,
        timeout: @statement_timeout_ms + 10_000
      )

    took = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, pages} ->
        :telemetry.execute([:bitblocks, :gin_pending, :cleaned], %{pages: pages, ms: took}, %{
          index: index
        })

        if took > 10_000,
          do: Logger.info("GinPending #{index}: #{pages} page(s) cleaned in #{took}ms")

        pages
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      message = Exception.message(e)
      Logger.error("GinPending #{index}: cleanup failed: #{message}")
      {:error, message}
  end
end
