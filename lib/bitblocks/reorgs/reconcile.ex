defmodule Bitblocks.Reorgs.Reconcile do
  @moduledoc """
  Reconciles the transaction rows of one orphaned block after a reorg (#34).

  Tip sync deletes an orphaned block's row, but its transactions keep
  `block_hash` = the orphan's hash. Each of those rows ends one of four ways:

    * **moved**: the transaction is in a block we store. If it's in the block
      that replaced the orphan at the same height, the replacement's
      merkleroot-verified txid list says so; otherwise a source lookup (node,
      then WhatsOnChain) names the block. The row takes that block's hash and
      height.
    * **removed**: the source says the transaction is unconfirmed, or doesn't
      know it. No block in the chain holds it, so the row stops being
      reported as confirmed. Its spend edges (`spend_index` rows it recorded
      as the spender) go with it.
    * **pending**: the source names a block we haven't stored yet. The row
      stays; when that block's transactions are fetched, the diff in
      `Chain.TxIngest.existing_txids/2` moves it.
    * **unknown**: the lookup failed (node down, rate limit). The row stays
      for the next run.

  Removal is a delete, not an "unconfirmed" mark. `transactions.block_hash`
  is required and every read path (API, proofs, tokens, collections) treats a
  stored row as confirmed, so a mark would need a new column on the largest
  table and a filter on every read. Deleting is safe to redo: a removed
  transaction that is mined later is fetched again with its new block, and a
  row is only removed on a source's answer, never on a failed lookup.

  The protocol rows derived from these transactions follow each one's end in
  the same database transaction: see `Bitblocks.Reorgs.ProtocolRewind`.

  Bounded: one block's rows, read through `transactions_block_hash_index`;
  writes are keyed by txid (the unique index) in chunks of 100.

  `plan/1` only reads. Reading the replacement's txid list may cache that
  verified list (and its `num_tx`) on the block row, as a tx fetch would.
  `apply_plan/1` writes, in one database transaction.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Repo
  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, Spend, Transaction, TxidSource, TxSources}
  alias Bitblocks.Reorgs
  alias Bitblocks.Reorgs.ProtocolRewind

  @chunk 100

  @type plan :: %{
          orphan_hash: String.t(),
          height: integer() | nil,
          rows: non_neg_integer(),
          repoint: [{String.t(), integer(), [String.t()]}],
          remove: [String.t()],
          pending: [String.t()],
          unknown: [String.t()],
          spends_to_remove: non_neg_integer(),
          protocols: ProtocolRewind.counts()
        }

  @doc """
  Sorts every row stored under `orphan_hash` by where its transaction is now.
  Changes no transaction or spend rows.

  `{:error, :block_still_stored}` when `orphan_hash` is still a stored block:
  it isn't an orphan in this index.
  """
  @spec plan(String.t(), keyword()) :: {:ok, plan()} | {:error, :block_still_stored}
  def plan(orphan_hash, opts \\ []) when is_binary(orphan_hash) do
    if Repo.exists?(from(b in Block, where: b.hash == ^orphan_hash)) do
      {:error, :block_still_stored}
    else
      rows =
        Repo.all(
          from(t in Transaction,
            where: t.block_hash == ^orphan_hash,
            select: {t.txid, t.block_height}
          )
        )

      # The rows' height, else the caller's, else the node's: it keeps the
      # headers of stale blocks, so an orphan with no rows left (#73) still
      # finds the reorg row that set it aside.
      height =
        Enum.find_value(rows, fn {_txid, h} -> if is_integer(h), do: h end) ||
          Keyword.get(opts, :height) || node_height(orphan_hash)

      txids = Enum.map(rows, &elem(&1, 0))

      {replacement_moves, rest} = in_replacement(txids, height)
      {found, remove, unknown} = lookup(rest, orphan_hash, height)
      {lookup_moves, pending} = stored_targets(found)

      repoint =
        (replacement_moves ++ lookup_moves)
        |> Enum.group_by(fn {hash, h, _txid} -> {hash, h} end, &elem(&1, 2))
        |> Enum.map(fn {{hash, h}, ids} -> {hash, h, Enum.sort(ids)} end)
        |> Enum.sort_by(fn {hash, h, _} -> {h, hash} end)

      {:ok,
       %{
         orphan_hash: orphan_hash,
         height: height,
         rows: length(rows),
         repoint: repoint,
         remove: Enum.sort(remove),
         pending: Enum.sort(pending),
         unknown: Enum.sort(unknown),
         spends_to_remove: count_spends(remove),
         protocols: ProtocolRewind.plan(moved_txids(repoint), remove)
       }}
    end
  end

  @doc """
  Applies a plan in one database transaction. Each write is also keyed on the
  orphan's hash, so a row that moved since the plan is left alone.

  Returns how many rows were moved and removed, how many spend edges were
  removed, how many rows still point at the orphan, and what happened to the
  protocol rows of the transactions that actually moved or went.
  """
  @spec apply_plan(plan()) ::
          {:ok,
           %{
             repointed: non_neg_integer(),
             removed: non_neg_integer(),
             spends_removed: non_neg_integer(),
             remaining: non_neg_integer(),
             protocols: ProtocolRewind.counts()
           }}
          | {:error, term()}
  def apply_plan(%{orphan_hash: orphan} = plan) do
    Repo.transaction(fn ->
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      {repointed, moved_protocols} =
        Enum.reduce(plan.repoint, {0, ProtocolRewind.none()}, fn {hash, height, txids}, acc ->
          moved =
            txids
            |> Enum.chunk_every(@chunk)
            |> Enum.flat_map(fn chunk ->
              {_n, moved} =
                Repo.update_all(
                  from(t in Transaction,
                    where: t.txid in ^chunk and t.block_hash == ^orphan,
                    select: t.txid
                  ),
                  set: [block_hash: hash, block_height: height, updated_at: now]
                )

              moved
            end)

          {count, protocols} = acc
          step = ProtocolRewind.moved(moved, hash, height)
          {count + length(moved), ProtocolRewind.add(protocols, step)}
        end)

      {gone, spends_removed} =
        for chunk <- Enum.chunk_every(plan.remove, @chunk), reduce: {[], 0} do
          {txs, spends} ->
            {s, _} = Repo.delete_all(from(s in Spend, where: s.spending_txid in ^chunk))

            {_t, deleted} =
              Repo.delete_all(
                from(t in Transaction,
                  where: t.txid in ^chunk and t.block_hash == ^orphan,
                  select: t.txid
                )
              )

            {deleted ++ txs, spends + s}
        end

      removed = length(gone)
      protocols = ProtocolRewind.add(moved_protocols, ProtocolRewind.removed(gone))

      remaining =
        Repo.aggregate(from(t in Transaction, where: t.block_hash == ^orphan), :count)

      Logger.warning(
        "Reconcile orphan=#{orphan} moved=#{repointed} removed=#{removed} " <>
          "spends_removed=#{spends_removed} remaining=#{remaining} " <>
          "protocols=#{inspect(protocols)}"
      )

      %{
        repointed: repointed,
        removed: removed,
        spends_removed: spends_removed,
        remaining: remaining,
        protocols: protocols
      }
    end)
  end

  @doc """
  Plans, and with `apply: true` applies, the reconcile for one orphan, then
  corrects the resolved reorg row that set it aside.

  Options:
    * `apply:` — write the changes (default false: a dry run).
    * `orphan_count:` — the number of blocks that reorg actually set aside,
      when the stored count is wrong. Left out, the count is kept.
    * `height:` — the orphan's height, when no row carries it and the node
      doesn't know the block.

  The reorg row is marked reconciled (`txs_reconciled_at`) once no row points
  at the orphan, and its summary is rewritten either way.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(orphan_hash, opts \\ []) do
    apply? = Keyword.get(opts, :apply, false) == true

    with {:ok, plan} <- plan(orphan_hash, opts) do
      reorg = if is_integer(plan.height), do: Reorgs.resolved_covering(plan.height)

      if apply? do
        with {:ok, result} <- apply_plan(plan) do
          changes = reorg_changes(reorg, opts, result.remaining == 0)
          reorg = update_reorg(reorg, changes)

          {:ok,
           %{
             applied: true,
             plan: plan,
             result: result,
             reorg: reorg,
             reorg_changes: changes
           }}
        end
      else
        settles? = plan.pending == [] and plan.unknown == []

        {:ok,
         %{
           applied: false,
           plan: plan,
           result: nil,
           reorg: reorg,
           reorg_changes: reorg_changes(reorg, opts, settles?)
         }}
      end
    end
  end

  # -- reorg row ----------------------------------------------------------------

  # Field => {old, new}, for fields that would change.
  defp reorg_changes(nil, _opts, _settled?), do: %{}

  defp reorg_changes(reorg, opts, settled?) do
    count =
      case Keyword.fetch(opts, :orphan_count) do
        {:ok, n} when is_integer(n) and n != reorg.orphan_count ->
          %{orphan_count: {reorg.orphan_count, n}}

        _ ->
          %{}
      end

    reconciled =
      if settled? and is_nil(reorg.txs_reconciled_at),
        do: %{txs_reconciled_at: {nil, DateTime.utc_now() |> DateTime.truncate(:second)}},
        else: %{}

    changes = Map.merge(count, reconciled)
    new = Map.new(changes, fn {k, {_old, v}} -> {k, v} end)
    preview = Reorgs.summary(struct(reorg, new))

    if preview == reorg.summary,
      do: changes,
      else: Map.put(changes, :summary, {reorg.summary, preview})
  end

  defp update_reorg(nil, _changes), do: nil
  defp update_reorg(reorg, changes) when changes == %{}, do: reorg

  defp update_reorg(reorg, changes) do
    opts = for {k, {_old, v}} <- changes, k != :summary, do: {k, v}

    case Reorgs.update_after_reconcile(reorg, opts) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.error("Reconcile: reorg row update failed: #{inspect(changeset.errors)}")
        reorg
    end
  end

  # -- classification -----------------------------------------------------------

  # Txids also in the block that replaced the orphan at its height, by that
  # block's merkleroot-verified txid list. Returns {[{hash, height, txid}], rest}.
  defp in_replacement([], _height), do: {[], []}
  defp in_replacement(txids, nil), do: {[], txids}

  defp in_replacement(txids, height) do
    with %Block{} = replacement <- Chain.get_block_at_height(height),
         {:ok, list, replacement} <- TxidSource.txids(replacement) do
      in_list = MapSet.new(list)
      {hit, rest} = Enum.split_with(txids, &MapSet.member?(in_list, &1))
      {Enum.map(hit, &{replacement.hash, replacement.height, &1}), rest}
    else
      nil ->
        {[], txids}

      {:error, reason} ->
        Logger.warning(
          "Reconcile: replacement txid list at #{height} unavailable: #{inspect(reason)}"
        )

        {[], txids}
    end
  end

  defp node_height(hash) do
    case Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli).getblockheader(hash, true) do
      %{"height" => height} when is_integer(height) -> height
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Asks the sources where each txid is. Returns {found, remove, unknown},
  # found as [{txid, blockhash}].
  defp lookup([], _orphan, _height), do: {[], [], []}

  defp lookup(txids, orphan, height) do
    probe = %Block{hash: orphan, height: height}

    txids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      results = TxSources.fetch_raw(chunk, probe)
      Enum.map(chunk, &{&1, classify(Map.get(results, &1), orphan)})
    end)
    |> Enum.reduce({[], [], []}, fn
      {txid, {:found, hash}}, {found, remove, unknown} ->
        {[{txid, hash} | found], remove, unknown}

      {txid, :remove}, {found, remove, unknown} ->
        {found, [txid | remove], unknown}

      {txid, :unknown}, {found, remove, unknown} ->
        {found, remove, [txid | unknown]}
    end)
  end

  defp classify(%{"blockhash" => hash}, orphan) when is_binary(hash) and hash not in ["", orphan],
    do: {:found, hash}

  # A source still naming the orphan with 0 or no confirmations is telling us
  # that block is off the chain, and the tx isn't in the replacement's verified
  # txid list (those were matched before any lookup): no block on the chain
  # holds it. The node and WhatsOnChain both answer this way (957,301,
  # 2026-11-04).
  defp classify(%{"blockhash" => orphan} = tx, orphan) do
    case tx["confirmations"] do
      n when is_integer(n) and n > 0 -> :unknown
      _zero_or_missing -> :remove
    end
  end

  # A body with no block: in the mempool, not in any block.
  defp classify(%{} = _tx, _orphan), do: :remove
  # Neither source knows the transaction.
  defp classify({:error, :not_found}, _orphan), do: :remove
  defp classify(_other, _orphan), do: :unknown

  # Splits found txids into moves to stored blocks and those still pending.
  defp stored_targets([]), do: {[], []}

  defp stored_targets(found) do
    hashes = found |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    heights =
      Repo.all(from(b in Block, where: b.hash in ^hashes, select: {b.hash, b.height}))
      |> Map.new()

    Enum.reduce(found, {[], []}, fn {txid, hash}, {moves, pending} ->
      case Map.fetch(heights, hash) do
        {:ok, h} -> {[{hash, h, txid} | moves], pending}
        :error -> {moves, [txid | pending]}
      end
    end)
  end

  defp moved_txids(repoint), do: Enum.flat_map(repoint, fn {_hash, _height, ids} -> ids end)

  defp count_spends(txids) do
    txids
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(0, fn chunk, acc ->
      acc + Repo.aggregate(from(s in Spend, where: s.spending_txid in ^chunk), :count)
    end)
  end
end
