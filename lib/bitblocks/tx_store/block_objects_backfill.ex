defmodule Bitblocks.TxStore.BlockObjectsBackfill do
  @moduledoc """
  Block objects for completed blocks that have none, as a backfill range
  (#94): what `Bitblocks.BackfillChains` runs for `"block_objects"`, so a
  whole height range goes as a chain of Oban jobs with dry run, pause, resume
  and status, rather than hundreds of hand-run `Release.store_block_objects/3`
  calls.

  Walks completed blocks with no `raw_object_stored_at` in height order,
  `:block_batch` at a time. Each is refetched from the node, written and
  verified by `BlockObject.fetch_and_store/2`, which stamps it: a block small
  enough to fetch whole (`Chain.RawBlock.eligible?/1`, 32 MB) in one put, a
  larger one streamed from node REST into a multipart upload
  (`BlockObject.store_streamed/2`,
  https://github.com/afomi/bitblocks/issues/86) when the chain runs with
  `large_blocks: true`. Blocks over the cap are counted under
  `details.too_large` either way. Off by default, so they are left unstored,
  until infra confirms the bucket's `s3:AbortMultipartUpload` permission and
  its lifecycle rule for incomplete uploads (docs/TX_STORAGE.md). A batch
  ends after each block it streams (one over the cap, or one the node
  refused whole as over it), so the chain's heartbeat beats between them.

  A failed block is counted, its first failures kept in `details`, and the
  walk goes on; `:max_failures` (3) failures in a row, counted across
  batches, raise, so the range is
  recorded `partial` and the chain retries, then fails, rather than walking
  past every block while the node or the store is down. An unready store
  fails the range before any fetch. A stamped block is never picked again,
  so a rerun after a full apply finds nothing. Dry run by default: counts and
  touches neither the node nor the store.
  """

  import Ecto.Query

  alias Bitblocks.Chain.{Block, RawBlock}
  alias Bitblocks.{Derivations, Repo, TxStore}
  alias Bitblocks.TxStore.BlockObject

  @kept_failures 5

  @doc """
  Runs over completed blocks from `from_height` to `to_height` inclusive and
  returns the `Derivations` report: `blocks_examined` and `rows_examined`
  are the blocks without an object read, `rows_changed` the objects stored
  (or, dry, that would be stored), and `rows_below_version` the blocks
  still to store (dry: the storable ones; applied: the failures). `details`
  counts `eligible` (blocks to store), `too_large` (those over the
  raw-block cap, streamed only with `large_blocks: true`), `stored` and
  `failed`, and keeps the first failures as `"height: reason"` strings.

  Options: `apply: true` to write (default false); `block_batch` (20);
  `max_failures` (3); `large_blocks` (false: count and skip blocks over the
  cap; true: stream them into a multipart upload); and the
  `Bitblocks.Derivations` options.
  """
  @spec run(non_neg_integer(), non_neg_integer(), keyword()) :: Derivations.report()
  def run(from_height, to_height, opts \\ []) do
    ctx = %{
      applied: Keyword.get(opts, :apply, false),
      from_height: from_height,
      to_height: to_height,
      block_batch: Keyword.get(opts, :block_batch, 20),
      max_failures: Keyword.get(opts, :max_failures, 3),
      large_blocks: Keyword.get(opts, :large_blocks, false) == true,
      opts: opts
    }

    Derivations.run(
      %{
        derivation: "block_objects",
        version: 1,
        from_height: from_height,
        to_height: to_height,
        # The last block read, and the failures in a row so far.
        cursor: {from_height - 1, 0, 0},
        details: %{eligible: 0, too_large: 0, stored: 0, failed: 0, failures: []},
        next: &next(&1, &2, ctx)
      },
      opts
    )
  end

  defp next({after_height, after_id, in_a_row}, report, ctx) do
    if ctx.applied and report.blocks_examined == 0, do: ensure_store_ready!()

    case batch({after_height, after_id}, ctx) do
      [] ->
        :done

      blocks ->
        # A streamed block can take minutes, so the batch ends after one and
        # the next batch (and heartbeat) follows.
        {report, in_a_row, last} =
          Enum.reduce_while(blocks, {report, in_a_row, nil}, fn b, {report, in_a_row, _} ->
            {report, in_a_row, streamed?} = block(b, {report, in_a_row}, ctx)
            step = if streamed?, do: :halt, else: :cont
            {step, {report, in_a_row, b}}
          end)

        if ctx.applied, do: Derivations.pause(ctx.opts)
        {:cont, {last.height, last.id, in_a_row}, report}
    end
  end

  defp ensure_store_ready! do
    case TxStore.ready?() do
      :ok -> :ok
      {:error, reason} -> raise "tx store not ready: #{inspect(reason)}"
    end
  end

  defp batch({after_height, after_id}, ctx) do
    Repo.all(
      from(b in Block,
        where: b.height >= ^ctx.from_height and b.height <= ^ctx.to_height,
        where: b.sync_state == "completed" and is_nil(b.raw_object_stored_at),
        where: b.height > ^after_height or (b.height == ^after_height and b.id > ^after_id),
        order_by: [asc: b.height, asc: b.id],
        limit: ^ctx.block_batch
      )
    )
  end

  defp block(block, {report, in_a_row}, ctx) do
    report = report |> bump(:blocks_examined, 1) |> bump(:rows_examined, 1)
    large? = not RawBlock.eligible?(block)
    report = if large?, do: detail(report, :too_large), else: report

    cond do
      large? and not ctx.large_blocks ->
        {report, in_a_row, false}

      not ctx.applied ->
        report = report |> detail(:eligible) |> bump(:rows_changed, 1)
        {bump(report, :rows_below_version, 1), in_a_row, false}

      true ->
        report = detail(report, :eligible)
        result = BlockObject.fetch_and_store(block, large: ctx.large_blocks)

        # A small-looking block the node refused whole was streamed too.
        fell_back? = not large? and streamed?(result)
        report = if fell_back?, do: detail(report, :too_large), else: report
        streamed? = large? or fell_back?

        case result do
          {:ok, _} ->
            {report |> detail(:stored) |> bump(:rows_changed, 1), 0, streamed?}

          {:error, reason} ->
            {report, in_a_row} = failed(report, block, reason, in_a_row + 1, ctx)
            {report, in_a_row, streamed?}
        end
    end
  end

  defp streamed?({:ok, %{streamed: true}}), do: true
  defp streamed?({:error, {:streamed, _}}), do: true
  defp streamed?(_), do: false

  defp failed(report, block, reason, in_a_row, ctx) do
    line = "#{block.height}: #{inspect(reason)}" |> String.slice(0, 300)

    report =
      report
      |> detail(:failed)
      |> bump(:rows_below_version, 1)
      |> update_in([:details, :failures], &Enum.take(&1 ++ [line], @kept_failures))

    if in_a_row >= ctx.max_failures do
      raise "#{in_a_row} block object failures in a row, last #{line}"
    end

    {report, in_a_row}
  end

  defp detail(report, key), do: update_in(report, [:details, key], &(&1 + 1))
  defp bump(report, key, n), do: Map.update!(report, key, &(&1 + n))
end
