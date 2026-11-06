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
        cursor: {from_height - 1, 0},
        details: %{},
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

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
        report = Enum.reduce(blocks, report, &block(&1, &2, ctx))
        last = List.last(blocks)
        {:cont, {last.height, last.id}, report}
    end
  end

  defp block(block, report, ctx) do
    block
    |> pages(%{report | blocks_examined: report.blocks_examined + 1}, 0, ctx)
  end

  defp pages(block, report, after_id, ctx) do
    result =
      Derivations.bounded(ctx.opts, fn ->
        case page(block, after_id, ctx) do
          [] -> :done
          rows -> {rows, Enum.sum_by(rows, &apply_row(&1, ctx))}
        end
      end)

    case result do
      :done ->
        report

      {rows, stored} ->
        if ctx.applied, do: Derivations.pause(ctx.opts)

        report = %{
          report
          | rows_examined: report.rows_examined + length(rows),
            rows_changed: report.rows_changed + stored
        }

        pages(block, report, List.last(rows).id, ctx)
    end
  end

  defp page(block, after_id, ctx) do
    from(t in Transaction,
      where: t.block_hash == ^block.hash and t.id > ^after_id,
      where: fragment("? @> ?", t.protocols, type(^["AIP"], {:array, :string})),
      order_by: t.id,
      limit: ^ctx.tx_batch
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
