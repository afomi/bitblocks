defmodule Bitblocks.Chain.TxPipeline.TxTypesBackfill do
  @moduledoc """
  Brings transaction types of completed blocks up to the current version
  (`docs/DERIVED_DATA.md`): `tx_types` on each tx, the block's coverage
  stamp `blocks.tx_types_version`, then the block's `type_counts`, stamped
  `type_counts_version`. It runs the same step modules the ingest runs
  (`Steps.ClassifyOutputs`'s classifier and `Steps.TypeCounts`), so the two
  can't disagree.

  Writes only what changes. Every `UPDATE` on `transactions` writes a new
  row version and an entry in each of its indexes, so a classifier bump
  that adds one type to a few txs must not rewrite every row. Coverage is
  recorded per block instead: a tx is typed at version N when its own
  `tx_types_version` is N or its block's `tx_types_version` is.

  Selects by version: a block is picked when its `tx_types_version` is nil
  or below `TxPipeline.version(:tx_types)`, and within it a tx is picked
  when its own stamp is too. Each picked tx is classified; only a tx whose
  types differ from the stored ones is written (`tx_types` and its own
  stamp). Once every picked tx of the block has decoded, the block is
  stamped, and its counts are rewritten (`Steps.TypeCounts`); a block that
  wasn't picked gets its counts rewritten only when its
  `type_counts_version` is below `TxPipeline.version(:type_counts)`. So a
  rerun after a full apply picks nothing, and a stopped run resumes where
  it stopped. `force: true` picks every block and row, and still writes
  only the rows whose types change.

  A tx that doesn't decode keeps its stamp, so it stays below the version;
  the report counts it under `details.undecodable`. Its block can't be
  stamped, so there the unchanged picked rows get their own stamps
  instead, and each of them is still typed at the version by its own row.

  Dry run by default: reads, classifies and counts, and writes only its
  `derivation_runs` row; `rows_changed` counts the tx rows an apply would
  write. With `apply: true` it writes one `UPDATE … FROM unnest(…)` per
  page that holds a changed row.

  Bounded: completed blocks in height order, `:block_batch` at a time, each
  block's txs paged by id on the `block_hash` index, `:tx_batch` at a time.
  Each page is one short transaction under a statement timeout, with a
  pause after each write (`Bitblocks.Derivations`). It never sets
  `updated_at`, which dates the tallies. Entry point:
  `Bitblocks.Release.backfill_tx_types/3`.

  Cost: a stamped block is skipped without reading its txs. In a picked
  block every tx row is read once for its stamp, and raw bytes only for
  the picked rows, so a rerun over a finished range reads no tx rows.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Transaction, TxPipeline}
  alias Bitblocks.Chain.TxPipeline.Steps
  alias Bitblocks.{Derivations, Repo}
  alias Bitblocks.TxTypes.Classifier

  @doc """
  Runs over completed blocks from `from_height` to `to_height` inclusive and
  returns the `Derivations` report. `rows_changed` is the tx rows written
  (in a dry run, to write); `details` holds `types_changed` (picked txs
  whose types differ from the stored ones), `undecodable`, `blocks_typed`
  (blocks stamped `tx_types_version`, or to stamp), `blocks_changed` (type
  counts written, or to write), `blocks_below_version` and
  `type_counts_version`.

  Options: `apply: true` to write (default false); `force: true` to pick
  every block and row; `block_batch` (100); `tx_batch` (1,000); and the
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
          blocks_typed: 0,
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
          select: %{
            id: b.id,
            hash: b.hash,
            height: b.height,
            time: b.time,
            typed: b.tx_types_version,
            stamp: b.type_counts_version
          }
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
    report = bump(report, :blocks_examined, 1)

    if ctx.force or below?(block.typed, ctx.version) do
      typed_block(block, report, ctx)
    else
      counts(block, report, false, ctx)
    end
  end

  # A block below the version: its txs paged and classified, then the block
  # stamped or, when a tx didn't decode, its unchanged rows one by one.
  defp typed_block(block, report, ctx) do
    acc = pages(block, %{report: report, undecodable: 0, unchanged: []}, 0, ctx)

    report =
      if acc.undecodable == 0 do
        if ctx.applied, do: stamp_block(block, ctx)
        detail(acc.report, :blocks_typed, 1)
      else
        bump(acc.report, :rows_changed, stamp_rows(acc.unchanged, ctx))
      end

    counts(block, report, true, ctx)
  end

  defp counts(block, report, picked?, ctx) do
    if picked? or ctx.force or below?(block.stamp, ctx.block_version) do
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

  defp pages(block, acc, after_id, ctx) do
    result =
      Derivations.bounded(ctx.opts, fn ->
        case page(block, after_id, ctx) do
          [] -> :done
          rows -> {rows, classify_and_write(rows, block, ctx)}
        end
      end)

    case result do
      :done ->
        acc

      {rows, page} ->
        if ctx.applied and page.written > 0, do: Derivations.pause(ctx.opts)

        report =
          acc.report
          |> bump(:rows_examined, length(rows))
          |> bump(:rows_changed, if(ctx.applied, do: page.written, else: page.changed))
          |> detail(:types_changed, page.changed)
          |> detail(:undecodable, page.undecodable)

        acc = %{
          report: report,
          undecodable: acc.undecodable + page.undecodable,
          unchanged: page.unchanged ++ acc.unchanged
        }

        pages(block, acc, List.last(rows).id, ctx)
    end
  end

  # Every row of the block, for its stamp; raw only for the picked ones.
  defp page(block, after_id, ctx) do
    Repo.all(
      from(t in Transaction,
        where: t.block_hash == ^block.hash and t.id > ^after_id,
        # `id + 0`, not `id`: see Bitblocks.Chain.TxPipeline.Backfill.page/3.
        order_by: fragment("? + 0", t.id),
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

  # Classifies the picked rows and writes only those whose types change.
  # `unchanged` holds the ids of picked rows below the version whose types
  # didn't, for `stamp_rows/2` should the block hold a tx that doesn't decode.
  defp classify_and_write(rows, block, ctx) do
    picked = Enum.filter(rows, &(ctx.force or below?(&1.tx_types_version, ctx.version)))

    typed =
      for row <- picked,
          {:ok, %{types: types}} <- [Classifier.classify_raw(row.raw, block: block)],
          do: {row, types}

    {changed, same} = Enum.split_with(typed, fn {row, types} -> row.tx_types != types end)

    %{
      written: if(ctx.applied and changed != [], do: write(changed, ctx.version), else: 0),
      changed: length(changed),
      unchanged: for({row, _} <- same, below?(row.tx_types_version, ctx.version), do: row.id),
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

  defp stamp_block(block, ctx) do
    Derivations.bounded(ctx.opts, fn ->
      {1, _} =
        Repo.update_all(
          from(b in Block, where: b.id == ^block.id),
          set: [tx_types_version: ctx.version]
        )
    end)
  end

  # A block that can't be stamped: its unchanged rows stamped instead,
  # `tx_batch` at a time. Returns how many (in a dry run, how many it would).
  defp stamp_rows(ids, %{applied: false}), do: length(ids)

  defp stamp_rows(ids, ctx) do
    ids
    |> Enum.chunk_every(ctx.tx_batch)
    |> Enum.reduce(0, fn chunk, total ->
      {n, _} =
        Derivations.bounded(ctx.opts, fn ->
          Repo.update_all(
            from(t in Transaction, where: t.id in ^chunk),
            set: [tx_types_version: ctx.version]
          )
        end)

      Derivations.pause(ctx.opts)
      total + n
    end)
  end

  # Rows and blocks of this batch still below the version, read back after
  # the writes: the explicit success check, summed over the range. A tx is
  # below when its own stamp and its block's both are.
  defp remaining(blocks, report, ctx) do
    ids = Enum.map(blocks, & &1.id)

    txs =
      Repo.one(
        from(t in Transaction,
          join: b in Block,
          on: b.hash == t.block_hash,
          where: b.id in ^ids,
          where: is_nil(b.tx_types_version) or b.tx_types_version < ^ctx.version,
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
