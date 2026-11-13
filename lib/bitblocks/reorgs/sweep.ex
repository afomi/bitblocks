defmodule Bitblocks.Reorgs.Sweep do
  @moduledoc """
  Protocol rows left behind by reorgs reconciled before the rewinds shipped
  (#73, "earlier reorgs").

  `Bitblocks.Reorgs.ProtocolRewind` follows tx rows as `Reconcile` moves or
  removes them. An orphan reconciled before that (957,301) left its protocol
  rows with nothing to drive them: they still carry a `block_hash` that no
  stored block has. This finds them from our own index and sends each through
  the same rewind:

    * **moved**: the tx row sits in a stored block now. Its rows follow it.
    * **removed**: no tx row is left, and the stored block at the row's height
      is `completed`, so a tx mined there would be stored. Its rows stop
      counting; a tx mined later is ingested again with its rows.
    * **unreconciled**: the tx row still carries the orphan's hash. Run
      `Release.reconcile_orphaned_block/2` on that hash first; it rewinds them.
    * **pending**: no tx row, and the block at that height isn't complete
      yet. Left for a later run.

  Collection items whose mint, trail or location rests on a moved or removed
  tx are moved, removed or marked for a re-trace by the rewind, as in a
  reconcile. A hop with no tx row at all can't be placed from our index (a
  removed tx and a lookup that failed both look like that), so those items are
  only reported, in `unindexed_hops`.

  Rows of protocols the rewind doesn't cover (Metanet, Bitcom, BAP) are
  counted in `by_protocol` and left alone.

  `plan/1` only reads. `run/1` writes only with `apply: true`, in one
  database transaction.
  """

  import Ecto.Query

  alias Bitblocks.Repo
  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.ProtocolRegistry.{Instance, Protocol}
  alias Bitblocks.Reorgs.ProtocolRewind

  @chunk 500

  @type plan :: %{
          rows: non_neg_integer(),
          by_protocol: %{String.t() => non_neg_integer()},
          orphans: [{String.t(), integer() | nil, non_neg_integer()}],
          moved: [{String.t(), integer(), [String.t()]}],
          removed: [String.t()],
          unreconciled: [{String.t(), [String.t()]}],
          pending: [String.t()],
          unindexed_hops: [{integer(), [String.t()]}],
          protocols: ProtocolRewind.counts()
        }

  @doc """
  Finds protocol rows under a block hash no stored block has, and what the
  rewind would do with them. Read-only.

  Options: `from:` and `to:` bound the rows' `block_height`.
  """
  @spec plan(keyword()) :: plan()
  def plan(opts \\ []) do
    rows = orphaned_rows(opts)
    txids = rows |> Enum.map(& &1.txid) |> Enum.uniq()
    tx_blocks = tx_blocks(txids)
    stored = stored_hashes(Enum.map(Map.values(tx_blocks), &elem(&1, 0)))
    completed = completed_heights(rows |> Enum.map(& &1.block_height) |> Enum.uniq())
    row_height = Map.new(rows, &{&1.txid, &1.block_height})

    {moved, removed, unreconciled, pending} =
      Enum.reduce(txids, {[], [], [], []}, fn txid, {mv, rm, un, pe} ->
        case Map.get(tx_blocks, txid) do
          {hash, height} ->
            if MapSet.member?(stored, hash),
              do: {[{hash, height, txid} | mv], rm, un, pe},
              else: {mv, rm, [{hash, txid} | un], pe}

          nil ->
            if MapSet.member?(completed, row_height[txid]),
              do: {mv, [txid | rm], un, pe},
              else: {mv, rm, un, [txid | pe]}
        end
      end)

    moved =
      moved
      |> Enum.group_by(fn {hash, h, _} -> {hash, h} end, &elem(&1, 2))
      |> Enum.map(fn {{hash, h}, ids} -> {hash, h, Enum.sort(ids)} end)
      |> Enum.sort_by(fn {hash, h, _} -> {h, hash} end)

    unreconciled =
      unreconciled
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {hash, ids} -> {hash, Enum.sort(ids)} end)
      |> Enum.sort()

    removed = Enum.sort(removed)

    %{
      rows: length(rows),
      by_protocol: rows |> Enum.frequencies_by(& &1.protocol),
      orphans:
        rows
        |> Enum.group_by(&{&1.block_hash, &1.block_height})
        |> Enum.map(fn {{hash, h}, rs} -> {hash, h, length(rs)} end)
        |> Enum.sort_by(fn {hash, h, _} -> {h || -1, hash} end),
      moved: moved,
      removed: removed,
      unreconciled: unreconciled,
      pending: Enum.sort(pending),
      unindexed_hops: unindexed_hops(),
      protocols: ProtocolRewind.plan(Enum.flat_map(moved, fn {_, _, ids} -> ids end), removed)
    }
  end

  @doc """
  Plans and, with `apply: true`, sends the moved and removed rows through
  `ProtocolRewind` in one database transaction. Returns
  `{:ok, %{applied, plan, result}}`; `result` is nil on a dry run.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    plan = plan(opts)

    if Keyword.get(opts, :apply, false) == true do
      Repo.transaction(fn ->
        moved =
          Enum.reduce(plan.moved, ProtocolRewind.none(), fn {hash, height, txids}, acc ->
            ProtocolRewind.add(acc, ProtocolRewind.moved(txids, hash, height))
          end)

        ProtocolRewind.add(moved, ProtocolRewind.removed(plan.removed))
      end)
      |> case do
        {:ok, result} -> {:ok, %{applied: true, plan: plan, result: result}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %{applied: false, plan: plan, result: nil}}
    end
  end

  # Protocol rows whose block_hash no stored block has. Rows above our highest
  # stored block may be in a block whose header hasn't arrived yet: not counted.
  defp orphaned_rows(opts) do
    tip = Repo.one(from(b in Block, select: max(b.height))) || -1

    query =
      from(i in Instance,
        join: p in Protocol,
        on: p.id == i.protocol_id,
        where: not is_nil(i.block_hash),
        where: is_nil(i.block_height) or i.block_height <= ^tip,
        where: fragment("NOT EXISTS (SELECT 1 FROM blocks b WHERE b.hash = ?)", i.block_hash),
        select: %{
          txid: i.txid,
          block_hash: i.block_hash,
          block_height: i.block_height,
          protocol: p.name
        }
      )

    query = if from = opts[:from], do: where(query, [i], i.block_height >= ^from), else: query
    query = if to = opts[:to], do: where(query, [i], i.block_height <= ^to), else: query
    Repo.all(query)
  end

  # txid => {block_hash, block_height} of its tx row, for those that have one.
  defp tx_blocks(txids) do
    txids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from(t in Transaction,
          where: t.txid in ^chunk,
          select: {t.txid, {t.block_hash, t.block_height}}
        )
      )
    end)
    |> Map.new()
  end

  defp stored_hashes(hashes) do
    hashes
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(&Repo.all(from(b in Block, where: b.hash in ^&1, select: b.hash)))
    |> MapSet.new()
  end

  defp completed_heights(heights) do
    heights
    |> Enum.reject(&is_nil/1)
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from(b in Block,
          where: b.height in ^chunk and b.sync_state == "completed",
          select: b.height
        )
      )
    end)
    |> MapSet.new()
  end

  # Items with a hop (mint, trail, location) that has no tx row: our index
  # can't say whether a reorg removed it. Reported, never marked.
  defp unindexed_hops do
    items =
      Repo.all(from(i in Item, select: {i.id, i.mint_txid, i.current_outpoint, i.trail}))

    hops =
      Map.new(items, fn {id, mint, outpoint, trail} ->
        at = if outpoint, do: String.replace(outpoint, ~r/_\d+$/, "")
        {id, Enum.uniq(Enum.reject([mint, at | trail || []], &is_nil/1))}
      end)

    have =
      hops
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.chunk_every(@chunk)
      |> Enum.flat_map(&Repo.all(from(t in Transaction, where: t.txid in ^&1, select: t.txid)))
      |> MapSet.new()

    hops
    |> Enum.map(fn {id, txids} -> {id, Enum.reject(txids, &MapSet.member?(have, &1))} end)
    |> Enum.reject(fn {_id, missing} -> missing == [] end)
    |> Enum.sort()
  end
end
