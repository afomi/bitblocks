defmodule Bitblocks.TxTypes.Export do
  @moduledoc """
  The research export (#51, step 5 of docs/TYPING_PIPELINE.md): transaction
  types by 10,000-block bucket, as a dataset someone can cite and check.

  Everything comes from the cached `Bitblocks.TxTypes.Counts` summary, so an
  export reads memory plus one small query for the backfill runs. The rows
  cover blocks `0..through_height`, every one verified complete (merkleroot
  rebuilt from its txids, every tx stored) and typed at the named version.

  Provenance travels with the data: the release that served it, the sha256 of
  the type definitions (`TxTypes.definitions_sha256/0`), the classifier and
  type-count versions, and the latest backfill runs that stamped the rows.
  `rows_sha256` is the sha256 of the CSV body (`csv/1`), so the JSON and the
  CSV can be checked against each other and against a later export.

  The data-pack exporter (a separate tool) reads blocks from a node; this
  export is the derived counts, which only this index holds, so it is served
  here: `GET /api/v1/types/export` and `GET /api/v1/types/export.csv`.
  """

  alias Bitblocks.{Derivations, TxTypes}
  alias Bitblocks.Chain.TxPipeline
  alias Bitblocks.TxTypes.Counts

  @bucket 10_000
  @schema_version 1
  @csv_header "type,from_height,to_height,txs\n"

  @doc "The dataset as a map, from `summary` (defaults to the cached one)."
  @spec dataset(Counts.summary()) :: map()
  def dataset(summary \\ Counts.get()) do
    rows = rows(summary)

    %{
      dataset: "bitblocks-tx-types-by-height",
      schema_version: @schema_version,
      title: "Bitcoin transaction types: first-seen heights and adoption by 10,000-block bucket",
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      coverage: %{
        status: summary.status,
        from_height: 0,
        through_height: summary[:through_height],
        complete_through: summary[:complete_through],
        tip_height: summary[:tip],
        bucket_blocks: @bucket,
        computed_at: summary[:computed_at],
        note: Counts.coverage_note(summary)
      },
      provenance: provenance(summary),
      columns: %{
        type: "type id, as on /types/:id and in priv/data/tx_types/types.json",
        from_height: "first block of the bucket",
        to_height: "last block of the bucket, cut at coverage.through_height",
        txs:
          "transactions with at least one output of the type; a tx with several types counts once under each"
      },
      types: types(summary),
      rows: rows,
      rows_sha256: sha256(csv_body(rows))
    }
  end

  @doc "The rows as CSV, with a header line: `type,from_height,to_height,txs`."
  @spec csv(Counts.summary()) :: String.t()
  def csv(summary \\ Counts.get()), do: summary |> rows() |> csv_body()

  @doc """
  One row per type per bucket with any txs, ordered by type then height.
  Empty unless the summary has counts.
  """
  @spec rows(Counts.summary()) :: [map()]
  def rows(%{status: :ok, adoption: adoption, through_height: through}) do
    adoption
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {id, %{per_10000_blocks: buckets}} ->
      for %{from_height: from, txs: txs} <- Enum.sort_by(buckets, & &1.from_height) do
        %{type: id, from_height: from, to_height: min(from + @bucket - 1, through), txs: txs}
      end
    end)
  end

  def rows(_summary), do: []

  defp types(%{status: :ok, types: counts} = summary) do
    known = Map.new(TxTypes.all(), &{&1.id, &1})

    counts
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {id, %{txs: txs, first_height: first}} ->
      adoption = Counts.adoption(summary, id) || %{}
      type = Map.get(known, id, %{})

      %{
        id: id,
        title: Map.get(type, :title),
        group: Map.get(type, :group),
        defined: Map.has_key?(known, id),
        txs: txs,
        first_seen_height: first,
        first_seen_time: adoption[:first_time],
        first_seen_txid: adoption[:first_txid]
      }
    end)
  end

  defp types(_summary), do: []

  defp provenance(summary) do
    %{
      release_sha: Bitblocks.Ops.release().sha,
      definitions_sha256: TxTypes.definitions_sha256(),
      versions: %{
        tx_types: TxPipeline.version(:tx_types),
        type_counts: summary[:version] || TxPipeline.version(:type_counts)
      },
      verified:
        "Every block from 0 to coverage.through_height is completed: its merkleroot rebuilt " <>
          "from its txids and every tx stored (docs/SYNCING.md), and its type counts stamped " <>
          "at versions.type_counts (docs/DERIVED_DATA.md).",
      runs: runs()
    }
  end

  # The latest runs that stamped tx_types and type_counts; none on error, so
  # the export still serves when the runs table can't be read.
  defp runs do
    Derivations.list_runs(derivation: "tx_types", limit: 5)
    |> Enum.map(&Derivations.public/1)
    |> Enum.map(&Map.take(&1, ~w(id derivation version from_height to_height applied
                                 rows_changed outcome started_at finished_at)a))
  rescue
    _ -> []
  end

  defp csv_body(rows) do
    @csv_header <>
      Enum.map_join(rows, fn r -> "#{r.type},#{r.from_height},#{r.to_height},#{r.txs}\n" end)
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
