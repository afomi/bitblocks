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

  With a height range, it walks the stored blocks in that range (any sync
  state), `:block_batch` at a time, and each block's txs on the `block_hash`
  index, paged by id. It selects through the block, not through
  `transactions.block_height`, because older rows have that column NULL and
  a height filter can't see them; a row it writes gets its block's height.
  Without a range (`Release.analyze_transactions/1`), it pages every stored
  tx by id. Each page (`:batch_size`, default 500) is one short transaction
  under a statement timeout, with a pause after each write
  (`Bitblocks.Derivations`). Dry run by default. It never sets `updated_at`,
  which dates the tallies.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, Transaction, TxPipeline}
  alias Bitblocks.{Derivations, Repo, TransactionParser}

  @doc """
  Runs over the txs of stored blocks from `from_height` to `to_height` (or
  every stored tx when both are nil). Options: `apply: true`, `force: true`
  (every row, whatever its stamp), `batch_size` (500), `block_batch` (100),
  and the `Bitblocks.Derivations` options.
  """
  @spec run(non_neg_integer() | nil, non_neg_integer() | nil, keyword()) ::
          Derivations.report()
  def run(from_height, to_height, opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      force: Keyword.get(opts, :force, false),
      version: TxPipeline.version(:script_analysis),
      from_height: from_height,
      to_height: to_height,
      batch_size: Keyword.get(opts, :batch_size, 500),
      block_batch: Keyword.get(opts, :block_batch, 100),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "script_analysis",
        version: ctx.version,
        from_height: from_height,
        to_height: to_height,
        cursor: if(from_height, do: {from_height - 1, 0}, else: {nil, 0}),
        details: %{undecodable: 0},
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  defp next({nil, after_id}, report, ctx) do
    case page(nil, after_id, ctx) do
      [] -> :done
      rows -> {:cont, {nil, List.last(rows).id}, process(rows, report, ctx)}
    end
  end

  # One batch of stored blocks after the cursor, keyset on (height, id).
  defp next({after_height, after_id}, report, ctx) do
    blocks =
      Repo.all(
        from(b in Block,
          where: b.height >= ^ctx.from_height and b.height <= ^ctx.to_height,
          where: b.height > ^after_height or (b.height == ^after_height and b.id > ^after_id),
          order_by: [asc: b.height, asc: b.id],
          limit: ^ctx.block_batch,
          select: %{id: b.id, hash: b.hash, height: b.height}
        )
      )

    case blocks do
      [] ->
        :done

      blocks ->
        report = Enum.reduce(blocks, report, &block(&1, &2, 0, ctx))
        last = List.last(blocks)
        {:cont, {last.height, last.id}, report}
    end
  end

  defp block(block, report, after_id, ctx) do
    case page(block, after_id, ctx) do
      [] ->
        report

      rows ->
        last_id = List.last(rows).id
        rows = Enum.map(rows, &%{&1 | block_height: &1.block_height || block.height})
        block(block, process(rows, report, ctx), last_id, ctx)
    end
  end

  defp page(block, after_id, ctx) do
    query =
      from(t in Transaction,
        where: t.id > ^after_id and not is_nil(t.raw),
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

    # Within a block, `id + 0`, not `id`: see Bitblocks.Chain.TxPipeline.Backfill.page/3.
    # Across the table (no block) the pkey order is the right plan.
    query =
      if block,
        do:
          query
          |> where([t], t.block_hash == ^block.hash)
          |> order_by([t], fragment("? + 0", t.id)),
        else: order_by(query, [t], asc: t.id)

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
            block_height: tx.block_height,
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
