defmodule Bitblocks.Chain.TxPipeline.CFilesBackfill do
  @moduledoc """
  Fills `c_files` for rows stored before the `index_c_files` step existed,
  or below its version (https://github.com/afomi/bitblocks/issues/147,
  https://github.com/afomi/bitblocks/issues/155, `docs/DERIVED_DATA.md`).

  Writes only to `c_files` and `c_file_misses`, never to `transactions`.
  Two passes over the range, one run:

    1. **B:// files.** Walks the txs tagged `B://` through their own partial
       index (`transactions_b_protocol_id_index`, the one `/files` reads)
       in id order, `:tx_batch` at a time, keeping those mined in the
       range. B:// txs are rare, so this pass reads that small index once
       and never walks blocks or the primary key. Bytes come from the row,
       else from the tx store (`TxStore.with_raw/1`; never WhatsOnChain).
       A tagged tx whose bytes we hold nowhere is counted under
       `details.no_raw` and left for a later run.
    2. **BCat files.** There is no index for the BCat tag, and none is
       added to `transactions`, so this pass walks the stored blocks in
       height order, as `backfill_bap` does, reading each block's txs
       tagged BCat on the `block_hash` index (`id + 0`, see
       `TxPipeline.Backfill`), `:tx_batch` at a time. Each head not yet
       indexed is assembled (`CFiles.index_bcat/3`, outside the page's
       database transaction): its chunks from our database or tx store,
       else WhatsOnChain as raw txs checked against their txids. A head
       that doesn't assemble stays unindexed, its reason in
       `c_file_misses`; an applied run tries it again.

  Writes only rows that change. A B:// file whose row already holds the
  same output, address and kind is left as it is, whatever version wrote
  it: v1 wrote B:// rows exactly as v2 does, so v2 doesn't rewrite them,
  and the applied run at v2 is what vouches for the range
  (`CFiles.indexed_through/1`). A BCat head already indexed is not
  assembled again. So a rerun after a full apply writes nothing.

  Each page is one short transaction under a statement timeout, with a
  pause after each write. Dry run by default; a dry run assembles nothing
  and fetches nothing. Entry point: `Bitblocks.Release.backfill_c_files/3`.
  """

  import Ecto.Query

  alias Bitblocks.{CFiles, Derivations, Repo, TxStore}
  alias Bitblocks.CFiles.{CFile, Miss}
  alias Bitblocks.Chain.{Block, Transaction}

  @doc """
  Runs over the B:// txs and BCat heads mined at heights `from_height` to
  `to_height` inclusive and returns the `Derivations` report:

    * `rows_examined`: the B:// txs and BCat heads read;
    * `rows_changed`: the file rows written (or, dry, to write or to
      assemble);
    * `rows_below_version`: the B:// file rows in the range still missing
      or changed, plus, dry, the BCat heads neither indexed nor tried at
      the version;
    * `blocks_examined`: the blocks the BCat pass walked.

  `details` counts `files_found`, `no_file` (tagged, but no B:// file of
  its own) and `no_raw` for the B:// pass, and for BCat: `bcat_heads`,
  `bcat_already` (indexed before this run), `bcat_indexed` (by this run),
  `bcat_unindexed` (couldn't be assembled; dry, tried before and missed)
  and `bcat_reasons`, those by reason.

  Options: `apply: true` to write (default false); `tx_batch` (200);
  `block_batch` (100); and the `Bitblocks.Derivations` options.
  """
  @spec run(non_neg_integer(), non_neg_integer(), keyword()) :: Derivations.report()
  def run(from_height, to_height, opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      from_height: from_height,
      to_height: to_height,
      tx_batch: Keyword.get(opts, :tx_batch, 200),
      block_batch: Keyword.get(opts, :block_batch, 100),
      version: CFiles.version(),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "c_files",
        version: ctx.version,
        from_height: from_height,
        to_height: to_height,
        cursor: {:b, 0},
        details: %{
          files_found: 0,
          no_file: 0,
          no_raw: 0,
          bcat_heads: 0,
          bcat_already: 0,
          bcat_indexed: 0,
          bcat_unindexed: 0,
          bcat_reasons: %{}
        },
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  # Pass 1: one page of B:// tagged txs after the cursor (a tx id); once
  # they're done, pass 2 starts before the range's first block.
  defp next({:b, after_id}, report, ctx) do
    started = Derivations.now()

    result =
      Derivations.bounded(ctx.opts, fn ->
        case after_id |> page(ctx) |> Derivations.fill_raw(ctx.opts) do
          [] -> :done
          txs -> {txs, Enum.map(txs, &tx(&1, ctx))}
        end
      end)

    case result do
      :done ->
        {:cont, {:bcat, Derivations.start_cursor(ctx.from_height, [])}, report}

      {txs, outcomes} ->
        Derivations.page_took(length(txs), started)
        if ctx.applied, do: Derivations.pause(ctx.opts)

        report =
          Enum.reduce(outcomes, bump(report, :rows_examined, length(txs)), &tally(&1, &2, ctx))

        {:cont, {:b, List.last(txs).id}, report}
    end
  end

  # Pass 2: one batch of stored blocks after the cursor, keyset on (height,
  # id), or from inside the block a batch stopped in.
  defp next({:bcat, cursor}, report, ctx) do
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
      [] ->
        :done

      blocks ->
        {:cont, cursor, report} =
          Derivations.walk_blocks(blocks, cursor, report, &bcat_block(&1, &2, &3, ctx))

        {:cont, {:bcat, cursor}, report}
    end
  end

  # The tag is a literal, spelled as the partial index's predicate, so the
  # planner can prove the index applies (Bitcom.Files.b_tagged/0 says why).
  defp page(after_id, ctx), do: after_id |> page_query(ctx) |> Repo.all()

  @doc false
  # The page query, for the test that reads its plan.
  def page_query(after_id, ctx) do
    from(t in Transaction,
      where: fragment("? @> ARRAY['B://']::varchar[]", t.protocols),
      where: t.id > ^after_id,
      where: t.block_height >= ^ctx.from_height and t.block_height <= ^ctx.to_height,
      order_by: [asc: t.id],
      limit: ^Derivations.page_limit(ctx.tx_batch),
      # Only the size; `Derivations.fill_raw/2` loads the bytes.
      select: %{
        id: t.id,
        txid: t.txid,
        block_height: t.block_height,
        raw_bytes: fragment("octet_length(?)", t.raw)
      }
    )
  end

  defp tx(row, ctx) do
    case TxStore.with_raw(row) do
      %{raw: raw} when is_binary(raw) and raw != "" ->
        rows = CFiles.rows(row.txid, raw, row.block_height)
        changed = changed(rows, row.txid)
        if ctx.applied, do: CFiles.write(changed)
        {rows, length(changed)}

      _ ->
        :no_raw
    end
  end

  # The rows not already stored as they are: a row is the same when its
  # output holds the same address and kind, whichever version wrote it.
  defp changed([], _txid), do: []

  defp changed(rows, txid) do
    current =
      Repo.all(from(c in CFile, where: c.txid == ^txid, select: {c.vout, c.sha256, c.kind}))
      |> MapSet.new()

    Enum.reject(rows, &MapSet.member?(current, {&1.vout, &1.sha256, &1.kind}))
  end

  defp tally(:no_raw, report, _ctx), do: update_in(report, [:details, :no_raw], &(&1 + 1))

  defp tally({rows, changed}, report, ctx) do
    report
    |> bump(:rows_changed, changed)
    |> bump(:rows_below_version, if(ctx.applied, do: 0, else: changed))
    |> update_in([:details], fn d ->
      d
      |> Map.update!(:files_found, &(&1 + length(rows)))
      |> Map.update!(:no_file, &(&1 + if(rows == [], do: 1, else: 0)))
    end)
  end

  # A block resumed inside was counted when it was first started.
  defp bcat_block(block, 0, report, ctx),
    do: bcat_pages(block, bump(report, :blocks_examined, 1), 0, ctx)

  defp bcat_block(block, after_id, report, ctx), do: bcat_pages(block, report, after_id, ctx)

  # Each page's read is its own short transaction; each head is assembled
  # after it, outside any transaction, so a slow chunk fetch holds no
  # connection open. Once the batch's time is up it stops after any page.
  defp bcat_pages(block, report, after_id, ctx) do
    started = Derivations.now()

    case Derivations.bounded(ctx.opts, fn -> bcat_page(block, after_id, ctx) end) do
      [] ->
        {:done, report}

      heads ->
        Derivations.page_took(length(heads), started)

        report =
          Enum.reduce(heads, bump(report, :rows_examined, length(heads)), &bcat_head(&1, &2, ctx))

        if ctx.applied, do: Derivations.pause(ctx.opts)
        last_id = List.last(heads).id

        if Derivations.time_up?(),
          do: {:within, last_id, report},
          else: bcat_pages(block, report, last_id, ctx)
    end
  end

  @doc false
  # A block's BCat heads after `after_id`, for the test that reads its plan.
  def bcat_page_query(block, after_id, ctx) do
    from(t in Transaction,
      where: t.block_hash == ^block.hash and t.id > ^after_id,
      where: fragment("? @> ARRAY['BCat']::varchar[]", t.protocols),
      # `id + 0`, not `id`: see Bitblocks.Chain.TxPipeline.Backfill.page/3.
      order_by: fragment("? + 0", t.id),
      limit: ^Derivations.page_limit(ctx.tx_batch),
      select: %{id: t.id, txid: t.txid, block_height: t.block_height}
    )
  end

  defp bcat_page(block, after_id, ctx), do: block |> bcat_page_query(after_id, ctx) |> Repo.all()

  defp bcat_head(head, report, ctx) do
    report = bump_detail(report, :bcat_heads, 1)

    cond do
      CFiles.bcat_indexed?(head.txid) ->
        bump_detail(report, :bcat_already, 1)

      ctx.applied ->
        case CFiles.index_bcat(head.txid, head.block_height) do
          {:ok, _row} ->
            report |> bump(:rows_changed, 1) |> bump_detail(:bcat_indexed, 1)

          {:error, reason} ->
            unindexed(report, reason)
        end

      miss = Repo.one(from(m in Miss, where: m.txid == ^head.txid and m.version >= ^ctx.version)) ->
        unindexed(report, String.to_existing_atom(miss.reason))

      true ->
        report |> bump(:rows_changed, 1) |> bump(:rows_below_version, 1)
    end
  end

  defp unindexed(report, reason) do
    report
    |> bump_detail(:bcat_unindexed, 1)
    |> update_in([:details, :bcat_reasons], &Map.update(&1, reason, 1, fn n -> n + 1 end))
  end

  defp bump(report, key, n), do: Map.update!(report, key, &(&1 + n))

  defp bump_detail(report, key, n), do: update_in(report, [:details, key], &(&1 + n))
end
