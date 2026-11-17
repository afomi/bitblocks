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

  Bounded: stored blocks in height order, `:block_batch` at a time; each
  block's ids read once on the `block_hash` index, then probed for spends
  `:id_window` at a time by primary key, and the picked txs run `:tx_batch`
  at a time. Each is one short transaction under a statement timeout, so a
  tx whose step fails rolls its batch back and stops the run (recorded as
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
  `id_window` (1,000 of a block's txs probed for spends per statement);
  `tx_batch` (200 txs run per transaction); and the `Bitblocks.Derivations`
  options.
  """
  @spec run(non_neg_integer(), non_neg_integer(), keyword()) :: Derivations.report()
  def run(from_height, to_height, opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      from_height: from_height,
      to_height: to_height,
      block_batch: Keyword.get(opts, :block_batch, 100),
      tx_batch: Keyword.get(opts, :tx_batch, 200),
      id_window: Keyword.get(opts, :id_window, 1_000),
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

  # One read of the block's ids on the block_hash index, then the ids in
  # windows of `:id_window`: the spend_index probe costs one index lookup per
  # row (about 0.8 ms cold on prod), so a query over the whole block grew with
  # it (47.8 s for 58,640 txs at 957,584, #89) however small the page. Each
  # window's probe is one bounded statement by primary key, and it sorts the
  # rows into those to run (analysed) and those to count (not analysed), so
  # every row is probed once.
  defp block(block, report, ctx) do
    ids =
      Derivations.bounded(ctx.opts, fn ->
        Repo.all(from(t in Transaction, where: t.block_hash == ^block.hash, select: t.id))
      end)
      |> Enum.sort()

    ids
    |> Enum.chunk_every(ctx.id_window)
    |> Enum.reduce(bump(report, :blocks_examined, 1), &window(&1, block, &2, ctx))
  end

  defp window(ids, block, report, ctx) do
    rows =
      Derivations.bounded(ctx.opts, fn ->
        Repo.all(
          from(t in without_spends(ids),
            order_by: t.id,
            select: {t.id, t.script_analysis_version}
          )
        )
      end)

    {picked, unanalysed} = Enum.split_with(rows, fn {_id, v} -> analysed?(v, ctx) end)
    picked = Enum.map(picked, &elem(&1, 0))

    if ctx.applied do
      picked
      |> Enum.chunk_every(ctx.tx_batch)
      |> Enum.each(fn batch ->
        Derivations.bounded(ctx.opts, fn ->
          from(t in Transaction, where: t.id in ^batch, order_by: t.id)
          |> Repo.all()
          |> Enum.each(&run_steps!(&1, block))
        end)

        Derivations.pause(ctx.opts)
      end)
    end

    report
    |> bump(:rows_examined, length(picked))
    |> bump(:rows_changed, length(picked))
    |> bump(
      :rows_below_version,
      length(unanalysed) + if(ctx.applied, do: 0, else: length(picked))
    )
    |> update_in([:details, :not_analysed], &(&1 + length(unanalysed)))
  end

  defp run_steps!(tx, block) do
    case Enum.find(TxPipeline.run_tx(tx, block), &match?({_, {:error, _}}, &1)) do
      nil -> :ok
      {step, {:error, message}} -> raise "block #{block.height} #{step}: #{message}"
    end
  end

  # Of `ids` (one block's), the txs that recorded no spend: all of a
  # coinbase's are absent by nature, so a flagged coinbase isn't one. By
  # primary key, not block_hash, so a window reads only its own rows.
  defp without_spends(ids) do
    from(t in Transaction,
      as: :tx,
      where: t.id in ^ids and fragment("? IS NOT TRUE", t.coinbase),
      where:
        not exists(from(s in Spend, where: s.spending_txid == parent_as(:tx).txid, select: 1))
    )
  end

  defp analysed?(version, ctx), do: is_integer(version) and version >= ctx.tags

  defp bump(report, key, n), do: Map.update!(report, key, &(&1 + n))
end
