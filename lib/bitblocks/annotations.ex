defmodule Bitblocks.Annotations do
  @moduledoc """
  Events placed on the chain by hand: forks, upgrades, halvings, mintings,
  milestones and real-world events. Admin only for now: CRUD at
  `/annotations` and `/api/v1/annotations`, drawn on `/chain-scrubber` and
  `/tx-graph`.

  An annotation is anchored by a height, a txid or a moment in time
  (`occurred_at`), and draws at `resolved_height`, derived on every save:

    1. a txid we hold: that tx's block height (`resolved_by: "txid"`);
    2. else the height given (`"height"`);
    3. else the first block mined at or after `occurred_at` (`"time"`);
       before the genesis block's time it stays off the chain
       (`"before_genesis"`), and after our tip, or just past a gap in our
       headers, it waits.

  An anchor that can't be placed yet (a tx not synced, a date past our tip)
  leaves `resolved_height` nil; `resolve_all/0` tries every such row again.

  Changes broadcast `:annotations_changed` on the `"chain_annotations"` topic,
  so open scrubbers redraw.
  """

  import Ecto.Query

  alias Bitblocks.Annotations.Annotation
  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Repo

  @pubsub Bitblocks.PubSub
  @topic "chain_annotations"
  @seed_path "priv/data/chain_annotations.json"

  def topic, do: @topic
  def kinds, do: Annotation.kinds()

  @doc "Every annotation, in chain order; unplaced ones last, by date."
  def list do
    Annotation
    |> order_by([a], asc_nulls_last: a.resolved_height, asc_nulls_last: a.occurred_at, asc: a.id)
    |> Repo.all()
  end

  @doc "Annotations that draw at a height in `from..to`, in chain order."
  def list_between(from, to) when is_integer(from) and is_integer(to) do
    Annotation
    |> where([a], a.resolved_height >= ^from and a.resolved_height <= ^to)
    |> order_by([a], asc: a.resolved_height, asc: a.id)
    |> Repo.all()
  end

  def get(id), do: Repo.get(Annotation, id)

  def change(%Annotation{} = annotation, attrs \\ %{}),
    do: Annotation.changeset(annotation, attrs)

  def create(attrs) do
    %Annotation{}
    |> Annotation.changeset(attrs)
    |> put_resolution()
    |> Repo.insert()
    |> broadcast()
  end

  def update(%Annotation{} = annotation, attrs) do
    annotation
    |> Annotation.changeset(attrs)
    |> put_resolution()
    |> Repo.update()
    |> broadcast()
  end

  def delete(%Annotation{} = annotation), do: annotation |> Repo.delete() |> broadcast()

  @doc """
  Where an annotation with these anchors draws: `{height, resolved_by}`, with
  a nil height when it can't be placed on the chain we hold.
  """
  @spec resolve(%{
          height: integer() | nil,
          txid: String.t() | nil,
          occurred_at: DateTime.t() | nil
        }) ::
          {non_neg_integer() | nil, String.t() | nil}
  def resolve(%{txid: txid, height: height, occurred_at: occurred_at}) do
    cond do
      tx_height = txid && tx_height(txid) -> {tx_height, "txid"}
      is_integer(height) -> {height, "height"}
      occurred_at -> height_at(occurred_at)
      true -> {nil, nil}
    end
  end

  @doc "Re-resolves every annotation not yet placed. Returns how many it placed."
  def resolve_all do
    placed =
      Annotation
      |> where([a], is_nil(a.resolved_height))
      |> Repo.all()
      |> Enum.count(fn a ->
        case resolve(a) do
          {nil, by} ->
            if by != a.resolved_by,
              do: a |> Annotation.resolution_changeset(nil, by) |> Repo.update!()

            false

          {height, by} ->
            a |> Annotation.resolution_changeset(height, by) |> Repo.update!()
            true
        end
      end)

    if placed > 0, do: notify()
    placed
  end

  @doc """
  Adds the curated events in `#{@seed_path}` that aren't there yet (matched
  on kind and title), so it is safe to run again. Returns `{added, skipped}`.
  """
  def seed(path \\ Application.app_dir(:bitblocks, @seed_path)) do
    existing = MapSet.new(Repo.all(from a in Annotation, select: {a.kind, a.title}))

    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("annotations")
    |> Enum.reduce({0, 0}, fn attrs, {added, skipped} ->
      if MapSet.member?(existing, {attrs["kind"], attrs["title"]}) do
        {added, skipped + 1}
      else
        {:ok, _} = create(attrs)
        {added + 1, skipped}
      end
    end)
  end

  # -- resolution --------------------------------------------------------------

  defp put_resolution(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp put_resolution(changeset) do
    anchors = %{
      txid: Ecto.Changeset.get_field(changeset, :txid),
      height: Ecto.Changeset.get_field(changeset, :height),
      occurred_at: Ecto.Changeset.get_field(changeset, :occurred_at)
    }

    {height, by} = resolve(anchors)
    Ecto.Changeset.change(changeset, resolved_height: height, resolved_by: by)
  end

  defp tx_height(txid) do
    Repo.one(
      from t in Transaction,
        where: t.txid == ^txid and not is_nil(t.block_height),
        select: t.block_height,
        limit: 1
    )
  end

  # The first block mined at or after `at`, by height. Block times aren't
  # strictly increasing, so this is the first height whose time reaches `at`.
  defp height_at(%DateTime{} = at) do
    t = DateTime.to_unix(at)
    genesis_time = Repo.one(from b in Block, where: b.height == 0, select: b.time)

    if is_integer(genesis_time) and t < genesis_time do
      {nil, "before_genesis"}
    else
      height =
        Repo.one(
          from b in Block,
            where: b.time >= ^t,
            order_by: [asc: b.height],
            select: b.height,
            limit: 1
        )

      if placed_after_stored_block?(height, t), do: {height, "time"}, else: {nil, nil}
    end
  end

  # A header gap below the found block would put the event late: only accept
  # it when the block just before is stored and earlier than the moment.
  defp placed_after_stored_block?(nil, _t), do: false
  defp placed_after_stored_block?(0, _t), do: true

  defp placed_after_stored_block?(height, t) do
    prev = height - 1
    Repo.exists?(from b in Block, where: b.height == ^prev and b.time < ^t)
  end

  defp broadcast({:ok, _} = result) do
    notify()
    result
  end

  defp broadcast(error), do: error

  defp notify, do: Phoenix.PubSub.broadcast(@pubsub, @topic, :annotations_changed)
end
