defmodule Bitblocks.Chain.TxPipeline.ScriptAnalysisBackfill do
  @moduledoc """
  Brings script analysis up to the current version (`docs/DERIVED_DATA.md`):
  re-runs `TransactionParser.analyze/1` on every stored tx whose
  `script_analysis_version` is nil or below the `script_analysis` step's
  version, writes `output_types`, `protocols`, `coinbase`,
  `output_script_hashes`, `output_template_hashes`, `aip_signers` and the
  stamp, and re-indexes its Bitcom commands (idempotent per txid and output).

  Selects by version, so a rerun after a full apply picks nothing and a
  stopped run resumes. A tx that doesn't decode keeps its old stamp; the
  report counts it under `details.undecodable` and in `rows_below_version`.

  With a height range, it walks `block_height` windows of `:height_batch`
  (default 1,000) on the `block_height` index, each paged by id. Without one
  (`Release.analyze_transactions/1`), it pages every stored tx by id. Each
  page (`:batch_size`, default 500) is one short transaction under a
  statement timeout, with a pause after each write (`Bitblocks.Derivations`).
  Dry run by default. It never sets `updated_at`, which dates the tallies.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Transaction, TxPipeline}
  alias Bitblocks.{Derivations, Repo, TransactionParser}

  @doc """
  Runs over stored txs with `block_height` from `from_height` to `to_height`
  (or every stored tx when both are nil). Options: `apply: true`,
  `force: true` (every row, whatever its stamp), `batch_size` (500),
  `height_batch` (1,000), and the `Bitblocks.Derivations` options.
  """
  @spec run(non_neg_integer() | nil, non_neg_integer() | nil, keyword()) ::
          Derivations.report()
  def run(from_height, to_height, opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      force: Keyword.get(opts, :force, false),
      version: TxPipeline.version(:script_analysis),
      to_height: to_height,
      batch_size: Keyword.get(opts, :batch_size, 500),
      height_batch: Keyword.get(opts, :height_batch, 1_000),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "script_analysis",
        version: ctx.version,
        from_height: from_height,
        to_height: to_height,
        cursor: {from_height, 0},
        details: %{undecodable: 0},
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  defp next({nil, after_id}, report, ctx) do
    case page(nil, nil, after_id, ctx) do
      [] -> :done
      rows -> {:cont, {nil, List.last(rows).id}, process(rows, report, ctx)}
    end
  end

  defp next({lo, _after_id}, _report, %{to_height: to}) when lo > to, do: :done

  defp next({lo, after_id}, report, ctx) do
    hi = min(lo + ctx.height_batch - 1, ctx.to_height)

    case page(lo, hi, after_id, ctx) do
      [] -> {:cont, {hi + 1, 0}, report}
      rows -> {:cont, {lo, List.last(rows).id}, process(rows, report, ctx)}
    end
  end

  defp page(lo, hi, after_id, ctx) do
    query =
      from(t in Transaction,
        where: t.id > ^after_id and not is_nil(t.raw),
        order_by: [asc: t.id],
        limit: ^ctx.batch_size,
        select: [:id, :txid, :raw, :block_height, :block_hash]
      )

    query =
      if ctx.force,
        do: query,
        else:
          where(
            query,
            [t],
            is_nil(t.script_analysis_version) or t.script_analysis_version < ^ctx.version
          )

    query =
      if lo, do: where(query, [t], t.block_height >= ^lo and t.block_height <= ^hi), else: query

    Derivations.bounded(ctx.opts, fn -> Repo.all(query) end)
  end

  defp process(rows, report, ctx) do
    analyzed = Enum.map(rows, &{&1, TransactionParser.analyze(&1.raw)})
    decodable = for {tx, {:ok, meta}} <- analyzed, do: {tx, meta}
    undecodable = length(rows) - length(decodable)

    changed =
      if ctx.applied and decodable != [] do
        n = Derivations.bounded(ctx.opts, fn -> write(decodable) end)
        Derivations.pause(ctx.opts)
        n
      else
        length(decodable)
      end

    below = if ctx.applied, do: length(rows) - changed, else: length(rows)

    report
    |> Map.update!(:rows_examined, &(&1 + length(rows)))
    |> Map.update!(:rows_changed, &(&1 + changed))
    |> Map.update!(:rows_below_version, &(&1 + below))
    |> update_in([:details, :undecodable], &(&1 + undecodable))
  end

  # Per row: the columns differ in shape (a map, arrays), so no unnest.
  # Returns the rows written, read from Postgres's own counts.
  defp write(decodable) do
    Enum.reduce(decodable, 0, fn {tx, meta}, written ->
      {n, _} =
        Repo.update_all(
          from(t in Transaction, where: t.id == ^tx.id),
          set: [
            output_types: meta.output_types,
            protocols: meta.protocols,
            coinbase: meta.coinbase,
            script_analysis_version: meta.script_analysis_version,
            output_script_hashes: meta.output_script_hashes,
            output_template_hashes: meta.output_template_hashes,
            aip_signers: meta.aip_signers
          ]
        )

      # Bitcom commands are indexed from the analysis, so a re-analysis
      # indexes them too.
      Bitblocks.Bitcom.index(%{tx | protocols: meta.protocols})

      written + n
    end)
  end
end
