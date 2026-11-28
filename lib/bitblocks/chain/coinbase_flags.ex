defmodule Bitblocks.Chain.CoinbaseFlags do
  @moduledoc """
  Finds completed blocks with no row flagged `coinbase` and flags the row
  that is their coinbase, so their block totals can be written.

  Until 2026-11-28 a coinbase the strict decoder rejected (a miner tag output
  holding a truncated push: 1Hash's and Bitcoin India's coinbases, around
  blocks 401,000..439,000) was analysed by the tolerant parser, which didn't
  read the null outpoint, and stored with `coinbase` false at the current
  script analysis version. A plain script analysis backfill selects by
  version and so never revisits those rows; this does, for just the one row
  per block.

  For each completed block in the range with no flagged row (the three
  blocks in `Steps.BlockTotals.unstored_coinbase/0` are skipped: their
  coinbase row can't be under them), it reads the rows under the block's
  hash with no input txids (a coinbase spends nothing; one query on the
  `block_hash` index), and checks each one's bytes: a row whose only input
  spends the null outpoint is the coinbase. One such row is flagged; none
  (the row isn't stored) or more than one is reported, never guessed.

  A dry run unless `apply: true`. Writes only `transactions.coinbase` on the
  rows it finds; the tally backfill over the same range then writes the
  block totals (`Release.backfill_tx_tallies/3`).
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, RawTx, Transaction}
  alias Bitblocks.Chain.TxPipeline.Steps.BlockTotals
  alias Bitblocks.{Repo, TxStore}

  @batch 500
  # Heights kept in each list of a report.
  @list_cap 200

  @type report :: %{
          applied: boolean(),
          examined: non_neg_integer(),
          unflagged: non_neg_integer(),
          flagged: non_neg_integer(),
          flagged_heights: [non_neg_integer()],
          not_stored: [non_neg_integer()],
          ambiguous: [non_neg_integer()],
          unwritten: [non_neg_integer()]
        }

  @doc """
  Runs over completed blocks from `from` to `to` inclusive. Options:
  `apply: true` to write (default false).
  """
  @spec run(non_neg_integer(), non_neg_integer(), keyword()) :: report()
  def run(from, to, opts \\ []) when is_integer(from) and is_integer(to) and from <= to do
    report = %{
      applied: Keyword.get(opts, :apply, false),
      examined: 0,
      unflagged: 0,
      flagged: 0,
      flagged_heights: [],
      not_stored: [],
      ambiguous: [],
      unwritten: []
    }

    batch(from, to, report)
  end

  defp batch(from, to, report) do
    blocks =
      Repo.all(
        from(b in Block,
          where: b.height >= ^from and b.height <= ^to,
          where: b.sync_state == "completed",
          order_by: [asc: b.height],
          limit: @batch,
          select: %{hash: b.hash, height: b.height}
        )
      )

    case blocks do
      [] ->
        report

      blocks ->
        report =
          blocks
          |> unflagged()
          |> Enum.reduce(%{report | examined: report.examined + length(blocks)}, &repair/2)

        batch(List.last(blocks).height + 1, to, report)
    end
  end

  # The blocks of the batch with no row flagged coinbase under their hash.
  defp unflagged(blocks) do
    skip = BlockTotals.unstored_coinbase()
    blocks = Enum.reject(blocks, &Map.has_key?(skip, &1.height))
    hashes = Enum.map(blocks, & &1.hash)

    flagged =
      Repo.all(
        from(t in Transaction,
          where: t.block_hash in ^hashes and t.coinbase == true,
          distinct: true,
          select: t.block_hash
        )
      )
      |> MapSet.new()

    Enum.reject(blocks, &MapSet.member?(flagged, &1.hash))
  end

  defp repair(block, report) do
    report = %{report | unflagged: report.unflagged + 1}

    case coinbase_rows(block) do
      [txid] ->
        # Applied, a row counts only when Postgres says it was written.
        if not report.applied or flag(block, txid) == 1 do
          %{
            report
            | flagged: report.flagged + 1,
              flagged_heights: capped(report.flagged_heights, block.height)
          }
        else
          %{report | unwritten: capped(report.unwritten, block.height)}
        end

      [] ->
        %{report | not_stored: capped(report.not_stored, block.height)}

      _several ->
        %{report | ambiguous: capped(report.ambiguous, block.height)}
    end
  end

  # Rows under the block with no input txids, whose bytes say coinbase.
  defp coinbase_rows(block) do
    Repo.all(
      from(t in Transaction,
        where: t.block_hash == ^block.hash,
        where: fragment("coalesce(cardinality(?), 0) = 0", t.input_txids),
        select: %{txid: t.txid, raw: t.raw}
      )
    )
    |> Enum.map(&TxStore.with_raw/1)
    |> Enum.filter(&coinbase_bytes?(&1.raw))
    |> Enum.map(& &1.txid)
  end

  defp coinbase_bytes?(raw) when is_binary(raw) do
    match?({:ok, %{inputs: [:coinbase]}}, RawTx.flows(raw))
  end

  defp coinbase_bytes?(_raw), do: false

  defp flag(block, txid) do
    {n, _} =
      Repo.update_all(
        from(t in Transaction,
          where: t.txid == ^txid and t.block_hash == ^block.hash,
          where: is_nil(t.coinbase) or t.coinbase == false
        ),
        set: [coinbase: true]
      )

    if n == 1, do: Logger.info("CoinbaseFlags block=#{block.height} flagged #{txid}")
    n
  end

  defp capped(list, height) when length(list) < @list_cap, do: list ++ [height]
  defp capped(list, _height), do: list
end
