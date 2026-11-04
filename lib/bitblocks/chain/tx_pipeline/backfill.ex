defmodule Bitblocks.Chain.TxPipeline.Backfill do
  @moduledoc """
  Recomputes the tally columns for blocks that completed before the tally
  steps existed: `total_input_satoshis`, `total_output_satoshis`,
  `fee_satoshis` and `burned_satoshis` on each tx, then the block totals.
  It runs the same step modules the ingest runs (`sats_out`, `burned`,
  `sats_in`, `fee`, `block_totals`), so the two can't disagree.

  Dry run by default: reads, computes and counts, writes nothing. With
  `apply: true` it writes only the rows whose values change, one `UPDATE …
  FROM unnest(…)` per page of txs, then runs `block_totals` on each block.

  Bounded: completed blocks in height order, `:block_batch` at a time, each
  block's txs paged by id, `:tx_batch` at a time. Ascending, so a page's
  previous outputs are stored (and tallied) before it. Entry point:
  `Bitblocks.Release.backfill_tx_tallies/3`.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, Transaction, TxPipeline}
  alias Bitblocks.Chain.TxPipeline.Steps
  alias Bitblocks.Repo

  @tally_steps [Steps.SatsOut, Steps.Burned, Steps.SatsIn, Steps.Fee]
  @columns [:total_input_satoshis, :total_output_satoshis, :fee_satoshis, :burned_satoshis]
  @block_columns [:sats_out, :fees, :miner_reward, :subsidy, :burned, :fees_verified]

  @type report :: %{
          applied: boolean(),
          from_height: integer(),
          to_height: integer(),
          blocks: non_neg_integer(),
          txs: non_neg_integer(),
          txs_changed: non_neg_integer(),
          sats_in_unknown: non_neg_integer(),
          blocks_changed: non_neg_integer(),
          unverified: [integer()]
        }

  @doc """
  Runs over completed blocks from `from_height` to `to_height` inclusive.

  Options: `apply: true` to write (default false); `block_batch` (100);
  `tx_batch` (1,000); `on_batch`, a function given the report so far after
  each batch of blocks (the Release task prints progress with it).
  """
  @spec run(non_neg_integer(), non_neg_integer(), keyword()) :: report()
  def run(from_height, to_height, opts \\ []) do
    report = %{
      applied: Keyword.get(opts, :apply, false),
      from_height: from_height,
      to_height: to_height,
      blocks: 0,
      txs: 0,
      txs_changed: 0,
      sats_in_unknown: 0,
      blocks_changed: 0,
      unverified: []
    }

    report
    |> batches(from_height - 1, to_height, opts)
    |> Map.update!(:unverified, &Enum.reverse/1)
  end

  defp batches(report, after_height, to_height, opts) do
    blocks =
      Repo.all(
        from(b in Block,
          where:
            b.sync_state == "completed" and b.height > ^after_height and b.height <= ^to_height,
          order_by: [asc: b.height],
          limit: ^Keyword.get(opts, :block_batch, 100)
        )
      )

    case blocks do
      [] ->
        report

      blocks ->
        report = Enum.reduce(blocks, report, &block(&1, &2, opts))
        if on_batch = opts[:on_batch], do: on_batch.(report)
        batches(report, List.last(blocks).height, to_height, opts)
    end
  end

  defp block(block, report, opts) do
    {report, sums} = pages(block, report, 0, empty_sums(), opts)

    totals =
      if report.applied do
        TxPipeline.run_block(block)
        Map.take(Repo.reload!(block), @block_columns)
      else
        Steps.BlockTotals.from_sums(sums, block.height)
      end

    changed? = Map.take(block, @block_columns) != totals

    %{
      report
      | blocks: report.blocks + 1,
        blocks_changed: report.blocks_changed + if(changed?, do: 1, else: 0),
        unverified:
          if(totals.fees_verified == false,
            do: [block.height | report.unverified],
            else: report.unverified
          )
    }
  end

  defp pages(block, report, after_id, sums, opts) do
    rows =
      Repo.all(
        from(t in Transaction,
          where: t.block_hash == ^block.hash and t.id > ^after_id,
          order_by: [asc: t.id],
          limit: ^Keyword.get(opts, :tx_batch, 1_000),
          select: map(t, [:id, :txid, :raw, :coinbase | @columns])
        )
      )

    case rows do
      [] ->
        {report, sums}

      rows ->
        computed =
          Enum.reduce(@tally_steps, Enum.map(rows, &%{txid: &1.txid, raw: &1.raw}), fn step,
                                                                                       acc ->
            step.run_chunk(acc, block)
          end)

        pairs = Enum.zip(rows, computed)
        changed = for {row, new} <- pairs, Map.take(row, @columns) != values(new), do: {row, new}

        if report.applied and changed != [], do: write(changed)

        report = %{
          report
          | txs: report.txs + length(rows),
            txs_changed: report.txs_changed + length(changed),
            sats_in_unknown:
              report.sats_in_unknown + Enum.count(computed, &is_nil(&1[:total_input_satoshis]))
        }

        sums =
          Enum.reduce(pairs, sums, fn {row, new}, acc -> add(acc, row.coinbase, values(new)) end)

        pages(block, report, List.last(rows).id, sums, opts)
    end
  end

  defp values(computed), do: Map.new(@columns, &{&1, computed[&1]})

  # One statement per page; only rows whose values change.
  defp write(changed) do
    ids = Enum.map(changed, fn {row, _} -> row.id end)
    column = fn name -> Enum.map(changed, fn {_, new} -> new[name] end) end

    Repo.query!(
      """
      UPDATE transactions AS t
      SET total_input_satoshis = u.sats_in,
          total_output_satoshis = u.sats_out,
          fee_satoshis = u.fee,
          burned_satoshis = u.burned,
          updated_at = now() AT TIME ZONE 'utc'
      FROM unnest($1::bigint[], $2::bigint[], $3::bigint[], $4::bigint[], $5::bigint[])
        AS u(id, sats_in, sats_out, fee, burned)
      WHERE t.id = u.id
      """,
      [
        ids,
        column.(:total_input_satoshis),
        column.(:total_output_satoshis),
        column.(:fee_satoshis),
        column.(:burned_satoshis)
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
