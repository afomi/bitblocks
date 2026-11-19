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

  Bounded: stored blocks in height order, up to `:block_batch` at a time;
  each block's ids read once on the `block_hash` index, then probed for
  spends `:id_window` at a time by primary key, and the picked txs run up to
  `:tx_batch` at a time. Each is one short transaction under a statement
  timeout, so a tx whose step fails rolls its batch back and stops the run
  (recorded as `partial`), with a pause after each write. Ascending, because
  a token transfer is judged by its inputs. Dry run by default.
  Entry point: `Bitblocks.Release.backfill_tx_steps/3`.

  Paced (`Bitblocks.Derivations`, https://github.com/afomi/bitblocks/issues/115):
  a batch ends once its time is up, between blocks or between the committed
  pages of a dense block, so a block of tens of thousands of txs is split
  into sub-batches; the cursor `{:within, height, tx_id}` resumes it after
  the last committed tx (`resume_after_tx:` from a chain's checkpoint), and
  every row is counted once across the split.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Spend, Transaction, TxPipeline}
  alias Bitblocks.{Derivations, Repo, TransactionParser}

  @doc """
  Runs over stored blocks from `from_height` to `to_height` inclusive and
  returns the `Derivations` report. `rows_changed` is the txs run (or, dry,
  to run), `details` holds `not_analysed`, and `rows_below_version` the txs
  still without spends, `not_analysed` included.

  Options: `apply: true` to write (default false); `block_batch` (100, the
  most a batch reads); `id_window` (1,000 of a block's txs probed for spends
  per statement); `tx_batch` (200, the most txs run per transaction);
  `resume_after_tx` (start inside the block at `from_height`, after that
  tx id); and the `Bitblocks.Derivations` options.
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
        cursor: Derivations.start_cursor(from_height, opts),
        details: %{not_analysed: 0},
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
        limit: ^Derivations.batch_limit(ctx.block_batch)
      )
      |> Derivations.blocks_after(cursor)
      |> Repo.all()

    case blocks do
      [] -> :done
      blocks -> Derivations.walk_blocks(blocks, cursor, report, &block(&1, &2, &3, ctx))
    end
  end

  # One read of the block's ids (those after `after_tx`, when a batch stopped
  # inside it) on the block_hash index, then the ids in windows of
  # `:id_window`: the spend_index probe costs one index lookup per row (about
  # 0.8 ms cold on prod), so a query over the whole block grew with it (47.8 s
  # for 58,640 txs at 957,584, #89) however small the page. Each window's
  # probe is one bounded statement by primary key, and it sorts the rows into
  # those to run (analysed) and those to count (not analysed), so every row is
  # probed once.
  defp block(block, after_tx, report, ctx) do
    ids =
      Derivations.bounded(ctx.opts, fn ->
        Repo.all(
          from(t in Transaction,
            where: t.block_hash == ^block.hash and t.id > ^after_tx,
            select: t.id
          )
        )
      end)
      |> Enum.sort()

    # A block resumed inside was counted when it was first started.
    report = if after_tx == 0, do: bump(report, :blocks_examined, 1), else: report

    ids
    |> Enum.chunk_every(ctx.id_window)
    |> windows(block, report, ctx)
  end

  defp windows([], _block, report, _ctx), do: {:done, report}

  defp windows([ids | rest], block, report, ctx) do
    case window(ids, block, report, ctx) do
      {:done, report} when rest != [] ->
        if Derivations.time_up?(),
          do: {:within, List.last(ids), report},
          else: windows(rest, block, report, ctx)

      result ->
        result
    end
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
    unanalysed = Enum.map(unanalysed, &elem(&1, 0))

    if ctx.applied do
      run_picked(picked, unanalysed, block, report, ctx)
    else
      {:done, count(report, picked, unanalysed, ctx)}
    end
  end

  # The picked txs in pages of `Derivations.page_limit/1`, each one bounded
  # transaction. Once the batch's time is up it stops after the page just
  # committed, counting the window's rows up to that page's last id; the
  # resume, after that id, probes and counts the rest, so each row once.
  defp run_picked(picked, unanalysed, block, report, ctx) do
    {page, rest} = Enum.split(picked, Derivations.page_limit(ctx.tx_batch))

    if page == [] do
      {:done, count(report, [], unanalysed, ctx)}
    else
      started = Derivations.now()

      Derivations.bounded(ctx.opts, fn ->
        from(t in Transaction, where: t.id in ^page, order_by: t.id)
        |> Repo.all()
        |> Enum.each(&run_steps!(&1, block))
      end)

      Derivations.page_took(length(page), started)
      Derivations.pause(ctx.opts)

      last = List.last(page)
      {done, later} = Enum.split_with(unanalysed, &(&1 <= last))
      report = count(report, page, done, ctx)

      cond do
        rest == [] -> {:done, count(report, [], later, ctx)}
        Derivations.time_up?() -> {:within, last, report}
        true -> run_picked(rest, later, block, report, ctx)
      end
    end
  end

  defp count(report, picked, unanalysed, ctx) do
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
