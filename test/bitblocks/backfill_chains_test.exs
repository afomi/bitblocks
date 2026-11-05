defmodule Bitblocks.BackfillChainsTest do
  # A backfill as a chain of Oban jobs (docs/DERIVED_DATA.md): one range per
  # job, carried across a restart, with nothing left `running`.
  use Bitblocks.DataCase, async: false
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.BackfillChains
  alias Bitblocks.Chain.{RawBlock, Transaction, TxIngest}
  alias Bitblocks.Derivations.{BackfillChain, Run}
  alias Bitblocks.Release
  alias Bitblocks.Workers.BackfillChainWorker

  defp store_tx(height) do
    {txid, hex} = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
    json = RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))
    :ok = TxIngest.store(json, block_fixture(%{height: height}))
    Repo.get_by!(Transaction, txid: txid)
  end

  defp unfill(tx) do
    Repo.update_all(from(t in Transaction, where: t.id == ^tx.id),
      set: [size_bytes: nil, raw_in_db: nil]
    )
  end

  defp size_chain(tx, opts) do
    {:ok, chain} =
      BackfillChains.start("tx_size", tx.id, tx.id + 2, Keyword.put_new(opts, :step, 2))

    chain
  end

  defp perform(chain, from, attempt \\ 1) do
    perform_job(BackfillChainWorker, %{"chain_id" => chain.id, "from" => from}, attempt: attempt)
  end

  defp reload(chain), do: Repo.get!(BackfillChain, chain.id)

  defp minutes_ago(m), do: DateTime.add(DateTime.utc_now(), -m * 60, :second)

  defp set_heartbeat(chain, at) do
    chain |> Ecto.Changeset.change(heartbeat_at: at) |> Repo.update!()
  end

  setup do
    tx = store_tx(90)
    unfill(tx)
    %{tx: tx}
  end

  test "walks the ranges job by job, then finishes", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    assert_enqueued(worker: BackfillChainWorker, args: %{chain_id: chain.id, from: tx.id})

    assert :ok = perform(chain, tx.id)
    assert reload(chain).next_from == tx.id + 2
    assert reload(chain).heartbeat_at == nil
    assert_enqueued(worker: BackfillChainWorker, args: %{chain_id: chain.id, from: tx.id + 2})
    assert Repo.get!(Transaction, tx.id).raw_in_db == true

    assert :ok = perform(chain, tx.id + 2)
    assert %{status: "done", finished_at: %DateTime{}} = reload(chain)

    assert [%Run{chain_id: id, outcome: "ok"}, %Run{outcome: "ok"}] =
             Repo.all(from(r in Run, order_by: r.id))

    assert id == chain.id
  end

  test "a dry run writes nothing and its counts stay readable", %{tx: tx} do
    chain = size_chain(tx, [])

    :ok = perform(chain, tx.id)
    :ok = perform(chain, tx.id + 2)

    assert Repo.get!(Transaction, tx.id).raw_in_db == nil

    assert %{
             rows_changed: 1,
             rows_below_version: 1,
             ranges_done: 2,
             ranges_total: 2,
             details: %{"no_raw" => 0}
           } = BackfillChains.status(chain.id)
  end

  test "a job back after a restart closes the dead run and reruns the range", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    set_heartbeat(chain, minutes_ago(30))

    dead =
      Repo.insert!(%Run{
        derivation: "tx_size",
        version: 1,
        chain_id: chain.id,
        outcome: "running",
        applied: true,
        started_at: minutes_ago(30)
      })

    assert :ok = perform(chain, tx.id, 2)

    assert %Run{outcome: "abandoned", finished_at: %DateTime{}} = Repo.get!(Run, dead.id)
    assert Repo.get!(Transaction, tx.id).raw_in_db == true
    assert Repo.aggregate(from(r in Run, where: r.outcome == "running"), :count) == 0
  end

  test "a rescued copy of a live job waits, and stops once the range moved on", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    set_heartbeat(chain, DateTime.utc_now())

    assert {:snooze, _} = perform(chain, tx.id, 2)
    assert Repo.get!(Transaction, tx.id).raw_in_db == nil

    chain |> Ecto.Changeset.change(next_from: tx.id + 2, heartbeat_at: nil) |> Repo.update!()

    assert {:cancel, :superseded} = perform(chain, tx.id, 2)
    assert Repo.get!(Transaction, tx.id).raw_in_db == nil
  end

  test "a paused chain runs nothing more until it is resumed", %{tx: tx} do
    chain = size_chain(tx, apply: true)

    Repo.delete_all(Oban.Job)
    {:ok, _} = BackfillChains.pause(chain.id)

    assert {:cancel, {:chain, "paused"}} = perform(chain, tx.id)
    refute_enqueued(worker: BackfillChainWorker)

    {:ok, _} = BackfillChains.resume(chain.id)
    assert_enqueued(worker: BackfillChainWorker, args: %{chain_id: chain.id, from: tx.id})
    assert reload(chain).status == "running"
  end

  test "a cancel ends the chain", %{tx: tx} do
    chain = size_chain(tx, apply: true)
    {:ok, _} = BackfillChains.cancel(chain.id)

    assert {:cancel, {:chain, "cancelled"}} = perform(chain, tx.id)
    assert {:error, _} = BackfillChains.resume(chain.id)
  end

  test "a second chain for the same derivation is refused until the first ends", %{tx: tx} do
    chain = size_chain(tx, apply: true)

    assert {:error, {:already_active, id}} = BackfillChains.start("tx_size", 1, 10, apply: true)
    assert id == chain.id

    {:ok, _} = BackfillChains.cancel(chain.id)
    assert {:ok, _} = BackfillChains.start("tx_size", 1, 10, apply: true)
  end

  test "a range out of attempts fails the chain, and it can be resumed", %{tx: tx} do
    chain = size_chain(tx, apply: true, statement_timeout_ms: -1)

    assert {:error, _} = perform(chain, tx.id, 20)
    assert %{status: "failed", error: error} = reload(chain)
    assert is_binary(error)

    assert {:ok, %{status: "running", error: nil}} = BackfillChains.resume(chain.id)
  end

  test "Release starts a chain and reads it back", %{tx: tx} do
    output =
      capture_io(fn ->
        Release.start_tx_sizes_backfill()
        [chain] = BackfillChains.list()
        assert chain.range_to == tx.id
        perform(chain, chain.range_from)
        Release.backfill_status(chain.id)
        Release.backfill_status()
      end)

    assert output =~ "STARTED"
    assert output =~ "DRY RUN"
    assert output =~ "1 row(s) to change"
  end
end
