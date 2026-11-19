defmodule Bitblocks.Chain.TxPipeline.BapBackfill do
  @moduledoc """
  Indexes BAP records on rows stored before the `index_bap` step existed
  (`docs/BAP.md`, `docs/DERIVED_DATA.md`).

  Picks rows tagged `AIP`, so it needs script analysis over the range first,
  and reads only those. Bounded: stored blocks in height order, `:block_batch`
  at a time, each block's AIP rows paged by id on the `block_hash` index,
  `:tx_batch` at a time, each page one short transaction under a statement
  timeout, with a pause after each write. Writes only to `bap_records`,
  idempotently, so a rerun finds nothing to add. Dry run by default.
  Entry point: `Bitblocks.Release.backfill_bap/3`.

  Paced (`Bitblocks.Derivations`): both sizes adapt, and a batch ends once
  its time is up, between blocks or after any page, inside a block as
  `{:within, height, tx_id}`, which a resume (`resume_after_tx:`) takes up.
  """

  import Ecto.Query

  alias Bitblocks.Bap
  alias Bitblocks.Bap.Record
  alias Bitblocks.Chain.{Block, Transaction, TxPipeline}
  alias Bitblocks.{Derivations, Repo}

  @doc """
  Runs over stored blocks from `from_height` to `to_height` inclusive and
  returns the `Derivations` report: `rows_examined` is the AIP rows read, and
  `rows_changed` the records stored (or, dry, found and not yet stored).

  Options: `apply: true` to write (default false); `block_batch` (100);
  `tx_batch` (200); and the `Bitblocks.Derivations` options.
  """
  @spec run(non_neg_integer(), non_neg_integer(), keyword()) :: Derivations.report()
  def run(from_height, to_height, opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      from_height: from_height,
      to_height: to_height,
      block_batch: Keyword.get(opts, :block_batch, 100),
      tx_batch: Keyword.get(opts, :tx_batch, 200),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "bap",
        version: TxPipeline.Steps.IndexBap.version(),
        from_height: from_height,
        to_height: to_height,
        cursor: Derivations.start_cursor(from_height, opts),
        details: %{},
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  # One batch of stored blocks after the cursor, keyset on (height, id), or
  # from inside the block a batch stopped in (`{:within, height, tx_id}`).
  defp next(cursor, report, ctx) do
    blocks =
      from(b in Block,
        where: b.height >= ^ctx.from_height and b.height <= ^ctx.to_height,
        order_by: [asc: b.height, asc: b.id],
        limit: ^Derivations.batch_limit(ctx.block_batch),
        select: %{id: b.id, hash: b.hash, height: b.height}
      )
      |> Derivations.blocks_after(cursor)
      |> Repo.all()

    case blocks do
      [] -> :done
      blocks -> Derivations.walk_blocks(blocks, cursor, report, &block(&1, &2, &3, ctx))
    end
  end

  # A block resumed inside was counted when it was first started.
  defp block(block, 0, report, ctx),
    do: pages(block, %{report | blocks_examined: report.blocks_examined + 1}, 0, ctx)

  defp block(block, after_id, report, ctx), do: pages(block, report, after_id, ctx)

  # Each page commits on its own, so once the batch's time is up it stops
  # after any page, and the resume picks up after that page's last tx.
  defp pages(block, report, after_id, ctx) do
    started = Derivations.now()

    result =
      Derivations.bounded(ctx.opts, fn ->
        case page(block, after_id, ctx) do
          [] -> :done
          rows -> {rows, Enum.sum_by(rows, &apply_row(&1, ctx))}
        end
      end)

    case result do
      :done ->
        {:done, report}

      {rows, stored} ->
        Derivations.page_took(length(rows), started)
        if ctx.applied, do: Derivations.pause(ctx.opts)

        report = %{
          report
          | rows_examined: report.rows_examined + length(rows),
            rows_changed: report.rows_changed + stored
        }

        last_id = List.last(rows).id

        if Derivations.time_up?(),
          do: {:within, last_id, report},
          else: pages(block, report, last_id, ctx)
    end
  end

  defp page(block, after_id, ctx) do
    from(t in Transaction,
      where: t.block_hash == ^block.hash and t.id > ^after_id,
      where: fragment("? @> ?", t.protocols, type(^["AIP"], {:array, :string})),
      # `id + 0`, not `id`: see Bitblocks.Chain.TxPipeline.Backfill.page/3.
      order_by: fragment("? + 0", t.id),
      limit: ^Derivations.page_limit(ctx.tx_batch)
    )
    |> Repo.all()
  end

  defp apply_row(tx, %{applied: true}), do: Bap.index(tx)

  defp apply_row(%Transaction{aip_signers: [_ | _]} = tx, _ctx) do
    found = tx.txid |> Bap.records(tx.raw) |> length()
    stored = Repo.aggregate(from(r in Record, where: r.txid == ^tx.txid), :count)
    max(found - stored, 0)
  end

  defp apply_row(_tx, _ctx), do: 0
end
