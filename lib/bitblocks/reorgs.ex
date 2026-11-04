defmodule Bitblocks.Reorgs do
  @moduledoc """
  Records of chain reorganizations.

  Phase 1 of #34: write an annotation when tip sync sees a fork, and surface
  the recent one as a site notice. Transaction rows and their spend edges are
  reconciled after the fact (`Bitblocks.Reorgs.Reconcile`); token, listing and
  other protocol rows are a later phase.

  `summary` is stored for the views, but always computed from the row's
  fields by `summary/1`, and rewritten whenever those fields change, so the
  sentence never outlives the facts it describes.
  """

  import Ecto.Query

  alias Bitblocks.Repo
  alias Bitblocks.Reorgs.Reorg

  # Tip sync reports a deep fork about once a minute. Collapse those into one row.
  @dedupe_seconds 6 * 3600
  # A deep fork that the worker has stopped reporting is no longer "happening now".
  @attention_seconds 2 * 3600
  # A resolved reorg stays on the banner for a day, then lives on the timeline.
  @resolved_notice_seconds 24 * 3600

  @doc """
  Inserts an annotation, or refreshes `last_seen_at` when the same fork was
  recorded inside the dedupe window.

  `now` is injectable so tests can place an event in time.
  """
  @spec record_observed(map(), DateTime.t()) :: {:ok, Reorg.t()} | {:error, Ecto.Changeset.t()}
  def record_observed(attrs, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    attrs = Map.new(attrs)
    fork_height = Map.fetch!(attrs, :fork_height)
    fork_point = Map.get(attrs, :fork_point)
    orphan_count = Map.get(attrs, :orphan_count)
    outcome = Map.fetch!(attrs, :outcome)

    case recent_match(fork_height, fork_point, outcome, now) do
      %Reorg{} = existing ->
        existing
        |> Ecto.Changeset.change(%{last_seen_at: now})
        |> Repo.update()

      nil ->
        fields = %{
          detected_at: now,
          last_seen_at: now,
          fork_height: fork_height,
          fork_point: fork_point,
          orphan_count: orphan_count,
          outcome: outcome
        }

        %Reorg{}
        |> Reorg.changeset(Map.put(fields, :summary, summary(struct(Reorg, fields))))
        |> Repo.insert()
    end
  end

  @doc """
  Corrects a reorg row after its transaction rows were reconciled, and
  rewrites its summary to match.

  Options: `:orphan_count` (the blocks actually set aside) and
  `:txs_reconciled_at` (set once no row points at an orphaned hash).
  Options left out keep their stored values.
  """
  @spec update_after_reconcile(Reorg.t(), keyword()) ::
          {:ok, Reorg.t()} | {:error, Ecto.Changeset.t()}
  def update_after_reconcile(%Reorg{} = reorg, opts) do
    changes = Map.new(Keyword.take(opts, [:orphan_count, :txs_reconciled_at]))
    updated = struct(reorg, changes)

    reorg
    |> Reorg.changeset(Map.put(changes, :summary, summary(updated)))
    |> Repo.update()
  end

  @doc """
  The most recent resolved reorg whose replaced heights include `height`
  (above its fork point, up to its fork height), or nil.
  """
  @spec resolved_covering(integer()) :: Reorg.t() | nil
  def resolved_covering(height) when is_integer(height) do
    Repo.one(
      from(r in Reorg,
        where: r.outcome == "resolved",
        where: r.fork_point < ^height and r.fork_height >= ^height,
        order_by: [desc: r.detected_at, desc: r.id],
        limit: 1
      )
    )
  end

  @doc "Annotations, highest height first."
  @spec list_reorgs() :: [Reorg.t()]
  def list_reorgs do
    Repo.all(from(r in Reorg, order_by: [desc: r.fork_height, desc: r.detected_at, desc: r.id]))
  end

  @doc """
  The reorg the site should announce right now, or nil.

  A `needs_attention` row is announced while tip sync is still reporting it.
  A `resolved` row is announced for a day after it was first seen.
  """
  @spec active_notice(DateTime.t()) :: Reorg.t() | nil
  def active_notice(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    attention_cutoff = DateTime.add(now, -@attention_seconds, :second)
    resolved_cutoff = DateTime.add(now, -@resolved_notice_seconds, :second)

    # A fork that a later run resolved no longer needs a person, even inside
    # the attention window.
    resolved_since =
      from(s in Reorg,
        where: s.outcome == "resolved",
        where: s.fork_height >= parent_as(:attention).fork_height,
        where: s.detected_at >= parent_as(:attention).last_seen_at,
        select: 1
      )

    attention =
      Repo.one(
        from(r in Reorg,
          as: :attention,
          where: r.outcome == "needs_attention",
          where: r.last_seen_at >= ^attention_cutoff,
          where: not exists(resolved_since),
          order_by: [desc: r.last_seen_at, desc: r.id],
          limit: 1
        )
      )

    case attention do
      %Reorg{} = reorg ->
        reorg

      nil ->
        Repo.one(
          from(r in Reorg,
            where: r.outcome == "resolved",
            where: r.detected_at >= ^resolved_cutoff,
            order_by: [desc: r.detected_at, desc: r.id],
            limit: 1
          )
        )
    end
  end

  defp recent_match(fork_height, fork_point, outcome, now) do
    cutoff = DateTime.add(now, -@dedupe_seconds, :second)

    base =
      from(r in Reorg,
        where: r.fork_height == ^fork_height,
        where: r.outcome == ^outcome,
        where: r.last_seen_at >= ^cutoff,
        order_by: [desc: r.id],
        limit: 1
      )

    query =
      if is_nil(fork_point) do
        from(r in base, where: is_nil(r.fork_point))
      else
        from(r in base, where: r.fork_point == ^fork_point)
      end

    Repo.one(query)
  end

  @doc """
  The sentence for a reorg row, computed from its fields.
  """
  @spec summary(Reorg.t()) :: String.t()
  def summary(%Reorg{outcome: "resolved"} = reorg) do
    "On #{when_seen(reorg)}, the node and this index disagreed at height #{reorg.fork_height}. " <>
      "They meet again at height #{reorg.fork_point}. " <>
      "#{blocks_phrase(reorg.orphan_count)} " <>
      "Headers from height #{reorg.fork_point + 1} were fetched again. " <>
      transactions_phrase(reorg)
  end

  def summary(%Reorg{outcome: "needs_attention"} = reorg) do
    "On #{when_seen(reorg)}, the node and this index disagreed at height #{reorg.fork_height}. " <>
      "The fork is deeper than 10 blocks. " <>
      "Headers were left as they were. " <>
      "An operator has to compare the node with this index."
  end

  defp when_seen(%Reorg{detected_at: at}), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp transactions_phrase(%Reorg{txs_reconciled_at: nil}),
    do: "Transaction rows from the replaced blocks are still in this index."

  defp transactions_phrase(%Reorg{orphan_count: 1}),
    do:
      "Transactions from the replaced block now point to the blocks that hold them. " <>
        "Any that no block holds were removed."

  defp transactions_phrase(%Reorg{}),
    do:
      "Transactions from the replaced blocks now point to the blocks that hold them. " <>
        "Any that no block holds were removed."

  defp blocks_phrase(1), do: "1 block between those heights was set aside."

  defp blocks_phrase(n) when is_integer(n),
    do: "#{n} blocks between those heights were set aside."

  defp blocks_phrase(_), do: "The blocks between those heights were set aside."
end
