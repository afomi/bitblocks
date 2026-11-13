defmodule Bitblocks.Chain.TxPipeline.Backfill do
  @moduledoc """
  Brings the tallies of completed blocks up to the current version
  (`docs/DERIVED_DATA.md`): `total_input_satoshis`, `total_output_satoshis`,
  `fee_satoshis` and `burned_satoshis` on each tx, stamped
  `tallies_version`, then the block totals, stamped `blocks.tallies_version`.
  It runs the same step modules the ingest runs (`TxPipeline.derivation_steps(:tallies)`
  and `block_totals`), so the two can't disagree.

  Selects by version: a tx is picked when its `tallies_version` is nil or
  below `TxPipeline.version(:tallies)`, and a block's totals are rewritten
  when it is below `TxPipeline.version(:block_totals)` or any of its txs was
  picked. So a rerun after a full apply picks nothing, and a stopped run
  resumes where it stopped. `force: true` picks every row in the range.

  Dry run by default: reads, computes and counts, and writes only its
  `derivation_runs` row. With `apply: true` it stamps every picked row,
  writing its values too, one `UPDATE … FROM unnest(…)` per page.

  Bounded: completed blocks in height order, `:block_batch` at a time, each
  block's txs paged by id, `:tx_batch` at a time. Each page is one short
  transaction under a statement timeout, with a pause after each write
  (`Bitblocks.Derivations`). Ascending, so a page's previous outputs are
  stored before it. Entry point: `Bitblocks.Release.backfill_tx_tallies/3`.

  Cost: every tx row in the range is read once (the stamp and the stored
  values, for the block sums); raw bytes are read only for picked rows.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Transaction, TxPipeline}
  alias Bitblocks.Chain.TxPipeline.Steps
  alias Bitblocks.{Derivations, Repo}

  @columns [:total_input_satoshis, :total_output_satoshis, :fee_satoshis, :burned_satoshis]
  @block_columns [:sats_out, :fees, :miner_reward, :subsidy, :burned, :fees_verified]
  # Heights kept in a report's unverified list.
  @unverified_cap 100

  @doc """
  Runs over completed blocks from `from_height` to `to_height` inclusive and
  returns the `Derivations` report; `details` holds `values_changed`,
  `sats_in_unknown`, `blocks_changed`, `block_values_changed`,
  `blocks_below_version`, `reward_unknown` (blocks with no coinbase known,
  so no reward to check, and no stamp) and `unverified` (heights failing
  `miner_reward <= subsidy + fees`).

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
      version: TxPipeline.version(:tallies),
      block_version: TxPipeline.version(:block_totals),
      from_height: from_height,
      to_height: to_height,
      block_batch: Keyword.get(opts, :block_batch, 100),
      tx_batch: Keyword.get(opts, :tx_batch, 1_000),
      steps:
        TxPipeline.derivation_steps(:tallies) ++
          Application.get_env(:bitblocks, :tx_backfill_extra_steps, []),
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "tallies",
        version: ctx.version,
        from_height: from_height,
        to_height: to_height,
        cursor: {from_height - 1, 0},
        details: %{
          block_totals_version: ctx.block_version,
          values_changed: 0,
          sats_in_unknown: 0,
          blocks_changed: 0,
          block_values_changed: 0,
          blocks_below_version: 0,
          reward_unknown: 0,
          unverified: []
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
          limit: ^ctx.block_batch
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
    {report, sums, picked} = pages(block, report, 0, empty_sums(), 0, ctx)

    if picked > 0 or ctx.force or below?(block.tallies_version, ctx.block_version) do
      totals =
        if ctx.applied do
          Derivations.bounded(ctx.opts, fn -> run_block!(block) end)
          Map.take(Repo.reload!(block), @block_columns)
        else
          Steps.BlockTotals.from_sums(sums, block.height)
        end

      changed? = Map.take(block, @block_columns) != totals

      report
      |> bump(:blocks_examined, 1)
      |> detail(:blocks_changed, 1)
      |> detail(:block_values_changed, if(changed?, do: 1, else: 0))
      |> detail(:reward_unknown, if(totals.miner_reward, do: 0, else: 1))
      |> unverified(totals.fees_verified == false, block.height)
    else
      bump(report, :blocks_examined, 1)
    end
  end

  # A block step that fails stops the run, so it is recorded, not skipped.
  defp run_block!(block) do
    case Enum.find(TxPipeline.run_block(block), &match?({_, {:error, _}}, &1)) do
      nil -> :ok
      {step, {:error, message}} -> raise "block #{block.height} #{step}: #{message}"
    end
  end

  defp pages(block, report, after_id, sums, picked, ctx) do
    result =
      Derivations.bounded(ctx.opts, fn ->
        rows = page(block, after_id, ctx)

        case rows do
          [] -> :done
          rows -> {rows, compute_and_write(rows, block, ctx)}
        end
      end)

    case result do
      :done ->
        {report, sums, picked}

      {rows, {pairs, n_picked, n_values_changed, n_unknown}} ->
        if ctx.applied and n_picked > 0, do: Derivations.pause(ctx.opts)

        report =
          report
          |> bump(:rows_examined, length(rows))
          |> bump(:rows_changed, n_picked)
          |> detail(:values_changed, n_values_changed)
          |> detail(:sats_in_unknown, n_unknown)

        sums =
          Enum.reduce(pairs, sums, fn {row, values}, acc -> add(acc, row.coinbase, values) end)

        pages(block, report, List.last(rows).id, sums, picked + n_picked, ctx)
    end
  end

  # Every row of the block (the block sums need them all), with raw only for
  # the picked ones, so a rerun reads no raw bytes.
  defp page(block, after_id, ctx) do
    Repo.all(
      from(t in Transaction,
        where: t.block_hash == ^block.hash and t.id > ^after_id,
        # `id + 0`, not `id`: ordered by the bare primary key with a LIMIT,
        # the planner may walk the pkey from after_id and filter on
        # block_hash, which for a block whose rows were stored late (high
        # ids) reads tens of millions of rows and passes the statement
        # timeout (tx_types chain #12 at 160,000, 2026-11-10). `id + 0` can't
        # use the pkey for order, so it reads the block's rows by
        # block_hash and sorts them; below the 400,000 stop a block holds a
        # few thousand txs at most.
        order_by: fragment("? + 0", t.id),
        limit: ^ctx.tx_batch,
        select: %{
          id: t.id,
          txid: t.txid,
          coinbase: t.coinbase,
          tallies_version: t.tallies_version,
          total_input_satoshis: t.total_input_satoshis,
          total_output_satoshis: t.total_output_satoshis,
          fee_satoshis: t.fee_satoshis,
          burned_satoshis: t.burned_satoshis,
          raw:
            fragment(
              "CASE WHEN ?::boolean OR ? IS NULL OR ? < ? THEN ? END",
              ^ctx.force,
              t.tallies_version,
              t.tallies_version,
              ^ctx.version,
              t.raw
            )
        }
      )
    )
  end

  defp compute_and_write(rows, block, ctx) do
    {picked, kept} =
      Enum.split_with(rows, &(ctx.force or below?(&1.tallies_version, ctx.version)))

    computed =
      Enum.reduce(ctx.steps, Enum.map(picked, &%{txid: &1.txid, raw: &1.raw}), fn step, acc ->
        step.run_chunk(acc, block)
      end)

    picked_pairs = Enum.zip(picked, Enum.map(computed, &values/1))
    values_changed = Enum.count(picked_pairs, fn {row, new} -> Map.take(row, @columns) != new end)

    if ctx.applied and picked_pairs != [], do: write(picked_pairs, ctx.version)

    kept_pairs = Enum.map(kept, &{&1, Map.take(&1, @columns)})

    {picked_pairs ++ kept_pairs, length(picked), values_changed,
     Enum.count(computed, &is_nil(&1[:total_input_satoshis]))}
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
          where: is_nil(t.tallies_version) or t.tallies_version < ^ctx.version,
          select: count()
        )
      )

    blocks_below =
      Repo.one(
        from(b in Block,
          where: b.id in ^ids,
          where: is_nil(b.tallies_version) or b.tallies_version < ^ctx.block_version,
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

  defp unverified(report, false, _height), do: report

  defp unverified(report, true, height) do
    update_in(report, [:details, :unverified], fn heights ->
      if length(heights) < @unverified_cap, do: heights ++ [height], else: heights
    end)
  end

  defp values(computed), do: Map.new(@columns, &{&1, computed[&1]})

  # One statement per page: every picked row gets its values and the stamp.
  defp write(pairs, version) do
    column = fn name -> Enum.map(pairs, fn {_, new} -> new[name] end) end

    Repo.query!(
      """
      UPDATE transactions AS t
      SET total_input_satoshis = u.sats_in,
          total_output_satoshis = u.sats_out,
          fee_satoshis = u.fee,
          burned_satoshis = u.burned,
          tallies_version = $6,
          updated_at = now() AT TIME ZONE 'utc'
      FROM unnest($1::bigint[], $2::bigint[], $3::bigint[], $4::bigint[], $5::bigint[])
        AS u(id, sats_in, sats_out, fee, burned)
      WHERE t.id = u.id
      """,
      [
        Enum.map(pairs, fn {row, _} -> row.id end),
        column.(:total_input_satoshis),
        column.(:total_output_satoshis),
        column.(:fee_satoshis),
        column.(:burned_satoshis),
        version
      ]
    )
  end

  defp empty_sums do
    %{
      sats_out: nil,
      sats_out_unknown: 0,
      fees: nil,
      fees_unknown: 0,
      reward: nil,
      coinbases: 0,
      burned: nil,
      burned_unknown: 0
    }
  end

  # The same sums BlockTotals.totals/1 takes in SQL, one row at a time.
  defp add(sums, true, v) do
    %{
      sums
      | reward: plus(sums.reward, v.total_output_satoshis),
        coinbases: sums.coinbases + 1
    }
    |> add_burned(v)
  end

  defp add(sums, _not_coinbase, v) do
    %{
      sums
      | sats_out: plus(sums.sats_out, v.total_output_satoshis),
        sats_out_unknown: sums.sats_out_unknown + unknown(v.total_output_satoshis),
        fees: plus(sums.fees, v.fee_satoshis),
        fees_unknown: sums.fees_unknown + unknown(v.fee_satoshis)
    }
    |> add_burned(v)
  end

  defp add_burned(sums, v) do
    %{
      sums
      | burned: plus(sums.burned, v.burned_satoshis),
        burned_unknown: sums.burned_unknown + unknown(v.burned_satoshis)
    }
  end

  # SQL sum semantics: nulls are skipped, and an all-null sum is null.
  defp plus(acc, nil), do: acc
  defp plus(nil, n), do: n
  defp plus(acc, n), do: acc + n

  defp unknown(nil), do: 1
  defp unknown(_), do: 0
end
