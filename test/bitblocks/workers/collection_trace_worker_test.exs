defmodule Bitblocks.Workers.CollectionTraceWorkerTest do
  @moduledoc """
  Collection syncs as Oban jobs (infra, 2026-10-30): deploys killed detached
  syncs. Trace batches are checkpointed per item, so a resumed run only does
  the remainder.
  """
  use Bitblocks.DataCase, async: true
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureLog

  require Logger

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.Workers.{CollectionSyncWorker, CollectionTraceWorker}

  setup do
    collection_txid = tx([funding_outpoint()], [contract("collection")]) |> publish(839_715)
    cid = "#{collection_txid}_0"
    mint1 = tx([cid], [contract(), item(cid, "T1", address())]) |> publish(839_716)
    mint2 = tx(["#{mint1}_0"], [contract(), item(cid, "T2", address())]) |> publish(839_717)
    OrdinalCollections.sync(cid, [mint1, mint2], follow: false)

    items = Repo.all(from i in Item, where: i.collection_id == ^cid, order_by: i.id)
    %{cid: cid, items: items}
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  test "traces a batch, skipping items already traced in this run", %{cid: cid, items: [a, b]} do
    started = now_iso()

    # `a` was traced after this run started (say, before a deploy interrupted it).
    a
    |> Ecto.Changeset.change(
      trace_state: "current",
      owner: "1Kept",
      traced_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert :ok =
             perform_job(CollectionTraceWorker, %{
               slug: cid,
               ids: [a.id, b.id],
               run_started_at: started
             })

    assert Repo.get!(Item, a.id).owner == "1Kept"
    assert Repo.get!(Item, b.id).trace_state == "current"
  end

  test "re-walks a moved item with no trail from its origin", %{cid: cid, items: [a, _]} do
    hop = tx([a.origin], [p2pkh(address(), 1)]) |> publish()
    spend(a.origin, hop, 0)

    a
    |> Ecto.Changeset.change(trace_state: "current", current_outpoint: "#{hop}_0", trail: [])
    |> Repo.update!()

    perform_job(CollectionTraceWorker, %{slug: cid, ids: [a.id], run_started_at: now_iso()})

    assert Repo.get!(Item, a.id).trail == [hop]
  end

  test "the last batch of a run logs the summary", %{cid: cid, items: items} do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :info], fn ->
        perform_job(CollectionTraceWorker, %{
          slug: cid,
          ids: Enum.map(items, & &1.id),
          run_started_at: now_iso()
        })
      end)

    assert log =~ "sync_ordinal_collection #{cid}: done"
  end

  test "Release.sync_ordinal_collection enqueues one sync job and returns" do
    assert {:ok, :enqueued, _id} = Bitblocks.Release.sync_ordinal_collection("rexxies")

    assert [%{args: %{"slug" => "rexxies", "trace" => true}}] =
             all_enqueued(worker: CollectionSyncWorker)

    # A second call while it's pending doesn't start another run.
    assert {:ok, :already_running, _} = Bitblocks.Release.sync_ordinal_collection("rexxies")
  end
end
