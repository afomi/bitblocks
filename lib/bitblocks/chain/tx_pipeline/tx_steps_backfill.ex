defmodule Bitblocks.Chain.TxPipeline.TxStepsBackfill do
  @moduledoc """
  Runs the `:tx` steps (`record_spends`, `index_tokens`, `index_bitcom`) for
  stored txs that never met them (`docs/DERIVED_DATA.md`).

  The sync skips a txid that is already stored, so a row from an earlier sync
  has no `spend_index` rows, and any output it spends reads as unspent.
  These steps have no per-row stamp; every non-coinbase tx has an input, so
  a tx with no spend row is one they never ran on. That is what this picks,
  so a rerun after a full apply finds nothing, and a stopped run resumes.
  All three steps are idempotent on their unique keys.

  They read the row's `coinbase` flag and `protocols`, so it picks only rows
  analysed with the current tags (`TransactionParser.protocol_tags_version/0`)
  and counts the rest under `details.not_analysed`: run script analysis over
  the range first. A run with `not_analysed` above 0 isn't finished.

  Bounded: stored blocks in height order, `:block_batch` at a time, each
  block's picked txs paged by id on the `block_hash` index, `:tx_batch` at a
  time. A page is one short transaction under a statement timeout, so a tx
  whose step fails rolls its page back and stops the run (recorded as
  `partial`), with a pause after each write. Ascending, because a token
  transfer is judged by its inputs. Dry run by default.
  Entry point: `Bitblocks.Release.backfill_tx_steps/3`.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Spend, Transaction, TxPipeline}
  alias Bitblocks.{Derivations, Repo, TransactionParser}

  @doc """
  Runs over stored blocks from `from_height` to `to_height` inclusive and
  returns the `Derivations` report. `rows_changed` is the txs run (or, dry,
  to run), `details` holds `not_analysed`, and `rows_below_version` the txs
  still without spends, `not_analysed` included.

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
      tags: TransactionParser.protocol_tags_version(),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "tx_steps",
        version: TxPipeline.version(:tx),
        from_height: from_height,
        to_height: to_height,
        cursor: {from_height - 1, 0},
        details: %{not_analysed: 0},
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  # One batch of stored blocks after the cursor, keyset on (height, id).
  defp next({after_height, after_id}, report, ctx) do
    blocks =
      Repo.all(
        from(b in Block,
          where: b.height >= ^ctx.from_height and b.height <= ^ctx.to_height,
          where: b.height > ^after_height or (b.height == ^after_height and b.id > ^after_id),
          order_by: [asc: b.height, asc: b.id],
          limit: ^ctx.block_batch
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
    report = pages(block, bump(report, :blocks_examined, 1), 0, ctx)
    not_analysed = Repo.aggregate(without_spends(block) |> not_analysed(ctx), :count)

    remaining =
      if ctx.applied,
        do: Repo.aggregate(without_spends(block), :count),
        else: not_analysed

    report
    |> bump(:rows_below_version, remaining)
    |> update_in([:details, :not_analysed], &(&1 + not_analysed))
  end

  defp pages(block, report, after_id, ctx) do
    page = fn ->
      rows =
        block
        |> without_spends()
        |> analysed(ctx)
        |> where([t], t.id > ^after_id)
        |> order_by([t], asc: t.id)
        |> limit(^ctx.tx_batch)
        |> Repo.all()

      if ctx.applied, do: Enum.each(rows, &run_steps!(&1, block))
      rows
    end

    case Derivations.bounded(ctx.opts, page) do
      [] ->
        report

      rows ->
        if ctx.applied, do: Derivations.pause(ctx.opts)

        report =
          report
          |> bump(:rows_examined, length(rows))
          |> bump(:rows_changed, length(rows))
          |> bump(:rows_below_version, if(ctx.applied, do: 0, else: length(rows)))

        pages(block, report, List.last(rows).id, ctx)
    end
  end

  defp run_steps!(tx, block) do
    case Enum.find(TxPipeline.run_tx(tx, block), &match?({_, {:error, _}}, &1)) do
      nil -> :ok
      {step, {:error, message}} -> raise "block #{block.height} #{step}: #{message}"
    end
  end

  # The block's txs that recorded no spend: all of a coinbase's are absent by
  # nature, so a flagged coinbase isn't one.
  defp without_spends(%Block{hash: hash}) do
    from(t in Transaction,
      as: :tx,
      where: t.block_hash == ^hash and fragment("? IS NOT TRUE", t.coinbase),
      where:
        not exists(from(s in Spend, where: s.spending_txid == parent_as(:tx).txid, select: 1))
    )
  end

  defp analysed(query, ctx), do: where(query, [t], t.script_analysis_version >= ^ctx.tags)

  defp not_analysed(query, ctx) do
    where(
      query,
      [t],
      is_nil(t.script_analysis_version) or t.script_analysis_version < ^ctx.tags
    )
  end

  defp bump(report, key, n), do: Map.update!(report, key, &(&1 + n))
end
