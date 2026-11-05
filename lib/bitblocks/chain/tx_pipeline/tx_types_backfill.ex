defmodule Bitblocks.Chain.TxPipeline.TxTypesBackfill do
  @moduledoc """
  Brings transaction types of completed blocks up to the current version
  (`docs/DERIVED_DATA.md`): `tx_types` on each tx, stamped
  `tx_types_version`, then the block's `type_counts`, stamped
  `type_counts_version`. It runs the same step modules the ingest runs
  (`Steps.ClassifyOutputs`'s classifier and `Steps.TypeCounts`), so the two
  can't disagree.

  Selects by version: a tx is picked when its `tx_types_version` is nil or
  below `TxPipeline.version(:tx_types)`, and a block's counts are rewritten
  when its stamp is below `TxPipeline.version(:type_counts)` or any of its
  txs was picked. So a rerun after a full apply picks nothing, and a
  stopped run resumes where it stopped. `force: true` picks every row.

  Dry run by default: reads, classifies and counts, and writes only its
  `derivation_runs` row. With `apply: true` it stamps every picked row, one
  `UPDATE … FROM unnest(…)` per page. A tx that doesn't decode keeps its
  stamp (nil), so it stays below the version; the report counts it under
  `details.undecodable`.

  Bounded: completed blocks in height order, `:block_batch` at a time, each
  block's txs paged by id on the `block_hash` index, `:tx_batch` at a time.
  Each page is one short transaction under a statement timeout, with a
  pause after each write (`Bitblocks.Derivations`). It never sets
  `updated_at`, which dates the tallies. Entry point:
  `Bitblocks.Release.backfill_tx_types/3`.

  Cost: every tx row in the range is read once for its stamp; raw bytes
  only for the picked rows, so a rerun over a finished range reads no raw.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Transaction, TxPipeline}
  alias Bitblocks.Chain.TxPipeline.Steps
  alias Bitblocks.{Derivations, Repo}
  alias Bitblocks.TxTypes.Classifier

  @doc """
  Runs over completed blocks from `from_height` to `to_height` inclusive and
  returns the `Derivations` report; `details` holds `types_changed` (picked
  txs whose types differ from the stored ones), `undecodable`,
  `blocks_changed`, `blocks_below_version` and `type_counts_version`.

  Options: `apply: true` to write (default false); `force: true` to pick
  every row; `block_batch` (100); `tx_batch` (1,000); and the
  `Bitblocks.Derivations` options (`pause_ms`, `statement_timeout_ms`,
  `command`, `on_batch`).
  """
  @spec run(non_neg_integer(), non_neg_integer(), keyword()) :: Derivations.report()
  def run(from_height, to_height, opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      force: Keyword.get(opts, :force, false),
      version: TxPipeline.version(:tx_types),
      block_version: TxPipeline.version(:type_counts),
      from_height: from_height,
      to_height: to_height,
      block_batch: Keyword.get(opts, :block_batch, 100),
      tx_batch: Keyword.get(opts, :tx_batch, 1_000),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "tx_types",
        version: ctx.version,
        from_height: from_height,
        to_height: to_height,
        cursor: {from_height - 1, 0},
        details: %{
          type_counts_version: ctx.block_version,
          types_changed: 0,
          undecodable: 0,
          blocks_changed: 0,
          blocks_below_version: 0
        },
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  # One batch of completed blocks after the cursor, keyset on (height, id).
  defp next({after_height, after_id}, report, ctx) do
    blocks =
      Repo.all(
        from(b in Block,
          where: b.sync_state == "completed",
          where: b.height >= ^ctx.from_height and b.height <= ^ctx.to_height,
          where: b.height > ^after_height or (b.height == ^after_height and b.id > ^after_id),
          order_by: [asc: b.height, asc: b.id],
          limit: ^ctx.block_batch,
          select: %{id: b.id, hash: b.hash, height: b.height, stamp: b.type_counts_version}
        )
      )

    case blocks do
      [] ->
        :done

      blocks ->
        report = Enum.reduce(blocks, report, &block(&1, &2, ctx))
        last = List.last(blocks)
        {:cont, {last.height, last.id}, remaining(blocks, report, ctx)}
    end
  end

  defp block(block, report, ctx) do
    {report, picked} = pages(block, report, 0, 0, ctx)
    report = bump(report, :blocks_examined, 1)

    if picked > 0 or ctx.force or below?(block.stamp, ctx.block_version) do
      if ctx.applied do
        Derivations.bounded(ctx.opts, fn ->
          Steps.TypeCounts.run_block(%Block{id: block.id, hash: block.hash, height: block.height})
        end)
      end

      detail(report, :blocks_changed, 1)
    else
      report
    end
  end

  defp pages(block, report, after_id, picked, ctx) do
    result =
      Derivations.bounded(ctx.opts, fn ->
        case page(block, after_id, ctx) do
          [] -> :done
          rows -> {rows, classify_and_write(rows, ctx)}
        end
      end)

    case result do
      :done ->
        {report, picked}

      {rows, %{picked: n_picked, written: written, changed: changed, undecodable: undecodable}} ->
        if ctx.applied and written > 0, do: Derivations.pause(ctx.opts)

        report =
          report
          |> bump(:rows_examined, length(rows))
          |> bump(:rows_changed, if(ctx.applied, do: written, else: n_picked - undecodable))
          |> detail(:types_changed, changed)
          |> detail(:undecodable, undecodable)

        pages(block, report, List.last(rows).id, picked + n_picked, ctx)
    end
  end

  # Every row of the block, for its stamp; raw only for the picked ones.
  defp page(block, after_id, ctx) do
    Repo.all(
      from(t in Transaction,
        where: t.block_hash == ^block.hash and t.id > ^after_id,
        order_by: [asc: t.id],
        limit: ^ctx.tx_batch,
        select: %{
          id: t.id,
          tx_types: t.tx_types,
          tx_types_version: t.tx_types_version,
          raw:
            fragment(
              "CASE WHEN ?::boolean OR ? IS NULL OR ? < ? THEN ? END",
              ^ctx.force,
              t.tx_types_version,
              t.tx_types_version,
              ^ctx.version,
              t.raw
            )
        }
      )
    )
  end

  defp classify_and_write(rows, ctx) do
    picked = Enum.filter(rows, &(ctx.force or below?(&1.tx_types_version, ctx.version)))

    typed =
      for row <- picked,
          {:ok, %{types: types}} <- [Classifier.classify_raw(row.raw)],
          do: {row, types}

    written = if ctx.applied and typed != [], do: write(typed, ctx.version), else: 0

    %{
      picked: length(picked),
      written: written,
      changed: Enum.count(typed, fn {row, types} -> row.tx_types != types end),
      undecodable: length(picked) - length(typed)
    }
  end

  # One statement per page. Type ids are slugs, never commas, so each row's
  # set travels as one comma-joined string.
  defp write(typed, version) do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE transactions AS t
        SET tx_types = string_to_array(u.types, ','),
            tx_types_version = $3
        FROM unnest($1::bigint[], $2::text[]) AS u(id, types)
        WHERE t.id = u.id
        """,
        [
          Enum.map(typed, fn {row, _} -> row.id end),
          Enum.map(typed, fn {_, types} -> Enum.join(types, ",") end),
          version
        ]
      )

    n
  end

  # Rows and blocks of this batch still below the version, read back after
  # the writes: the explicit success check, summed over the range.
  defp remaining(blocks, report, ctx) do
    hashes = Enum.map(blocks, & &1.hash)
    ids = Enum.map(blocks, & &1.id)

    txs =
      Repo.one(
        from(t in Transaction,
          where: t.block_hash in ^hashes,
          where: is_nil(t.tx_types_version) or t.tx_types_version < ^ctx.version,
          select: count()
        )
      )

    blocks_below =
      Repo.one(
        from(b in Block,
          where: b.id in ^ids,
          where: is_nil(b.type_counts_version) or b.type_counts_version < ^ctx.block_version,
          select: count()
        )
      )

    report
    |> bump(:rows_below_version, txs)
    |> detail(:blocks_below_version, blocks_below)
  end

  defp below?(nil, _version), do: true
  defp below?(stamp, version), do: stamp < version

  defp bump(report, key, n), do: Map.update!(report, key, &(&1 + n))

  defp detail(report, key, n), do: update_in(report, [:details, key], &(&1 + n))
end
