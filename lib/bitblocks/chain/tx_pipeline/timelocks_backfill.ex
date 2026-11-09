defmodule Bitblocks.Chain.TxPipeline.TimelocksBackfill do
  @moduledoc """
  Fills `timelocks` for rows stored before the `index_timelocks` step
  existed, or below its version (#76, `docs/DERIVED_DATA.md`).

  Writes only to `timelocks`, never to `transactions`: most txs carry no
  lock, so a run over the whole chain inserts the rare rows and changes
  nothing else.

  Picks the txs that can hold a lock, the way the step does
  (`Timelocks.candidate?/1`): an output script analysis left `unknown`, or
  no analysis yet. Reads raw bytes only for those. A candidate whose bytes
  aren't in the database (moved to the tx store) is counted under
  `details.no_raw` and left for a later run.

  Bounded: stored blocks in height order, `:block_batch` at a time, each
  block's candidates paged by id on the `block_hash` index, `:tx_batch` at
  a time, each page one short transaction under a statement timeout, with
  a pause after each write. Idempotent on (txid, vout, op_index): a lock
  already stored at the current version is not written again, so a rerun
  after a full apply writes nothing. Dry run by default.
  Entry point: `Bitblocks.Release.backfill_timelocks/3`.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.{Derivations, Repo, Timelocks}
  alias Bitblocks.Timelocks.Lock

  @doc """
  Runs over stored blocks from `from_height` to `to_height` inclusive and
  returns the `Derivations` report: `rows_examined` is the candidate txs
  read, `rows_changed` the lock rows written (or, dry, to write), and
  `rows_below_version` the lock rows in the range still missing or below
  the version. `details` counts `locks_found` by kind (`one_sat_lock`,
  `cltv`, `csv`), `enforced`, `conditional` and `no_raw`.

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
      version: Timelocks.version(),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "timelocks",
        version: ctx.version,
        from_height: from_height,
        to_height: to_height,
        cursor: {from_height - 1, 0},
        details: %{
          locks_found: 0,
          one_sat_lock: 0,
          cltv: 0,
          csv: 0,
          enforced: 0,
          conditional: 0,
          no_raw: 0
        },
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
    pages(block, %{report | blocks_examined: report.blocks_examined + 1}, 0, ctx)
  end

  defp pages(block, report, after_id, ctx) do
    result =
      Derivations.bounded(ctx.opts, fn ->
        case page(block, after_id, ctx) do
          [] -> :done
          txs -> {txs, Enum.map(txs, &tx(&1, block, ctx))}
        end
      end)

    case result do
      :done ->
        report

      {txs, outcomes} ->
        if ctx.applied, do: Derivations.pause(ctx.opts)

        report =
          Enum.reduce(outcomes, bump(report, :rows_examined, length(txs)), &tally(&1, &2, ctx))

        pages(block, report, List.last(txs).id, ctx)
    end
  end

  # The block's txs that may hold a lock: an output left unknown, or none analysed.
  defp page(block, after_id, ctx) do
    from(t in Transaction,
      where: t.block_hash == ^block.hash and t.id > ^after_id,
      where: is_nil(t.output_types) or fragment("jsonb_exists(?, 'unknown')", t.output_types),
      order_by: t.id,
      limit: ^ctx.tx_batch,
      select: %{id: t.id, txid: t.txid, raw: t.raw}
    )
    |> Repo.all()
  end

  defp tx(%{raw: raw}, _block, _ctx) when not is_binary(raw) or raw == "", do: :no_raw

  defp tx(%{txid: txid, raw: raw}, block, ctx) do
    rows = Timelocks.rows(txid, raw, block)
    missing = missing(rows, txid, ctx.version)
    if ctx.applied, do: Timelocks.write(missing)
    {rows, length(missing)}
  end

  # The rows not yet stored at the current version.
  defp missing([], _txid, _version), do: []

  defp missing(rows, txid, version) do
    current =
      Repo.all(
        from(l in Lock,
          where: l.txid == ^txid and l.version >= ^version,
          select: {l.vout, l.op_index}
        )
      )
      |> MapSet.new()

    Enum.reject(rows, &MapSet.member?(current, {&1.vout, &1.op_index}))
  end

  defp tally(:no_raw, report, _ctx), do: update_in(report, [:details, :no_raw], &(&1 + 1))

  defp tally({rows, written}, report, ctx) do
    report =
      report
      |> bump(:rows_changed, written)
      |> bump(:rows_below_version, if(ctx.applied, do: 0, else: written))

    Enum.reduce(rows, report, fn row, report ->
      update_in(report, [:details], fn d ->
        d
        |> Map.update!(:locks_found, &(&1 + 1))
        |> Map.update!(kind_key(row.kind), &(&1 + 1))
        |> Map.update!(:enforced, &(&1 + if(row.enforced, do: 1, else: 0)))
        |> Map.update!(:conditional, &(&1 + if(row.conditional, do: 1, else: 0)))
      end)
    end)
  end

  defp kind_key("1sat_lock"), do: :one_sat_lock
  defp kind_key("cltv"), do: :cltv
  defp kind_key("csv"), do: :csv

  defp bump(report, key, n), do: Map.update!(report, key, &(&1 + n))
end
