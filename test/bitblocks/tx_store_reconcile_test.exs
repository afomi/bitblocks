defmodule Bitblocks.TxStoreReconcileTest do
  @moduledoc """
  The tx store counted against the chain for a block range: every shortfall
  is a number, and a stamped tx whose object is missing or wrong is caught.
  """
  use Bitblocks.DataCase, async: false

  import ExUnit.CaptureIO
  import Bitblocks.FirstSpendFixtures

  alias Bitblocks.Chain.Transaction
  alias Bitblocks.TxStore

  setup do
    insert_first_spend()
    raw = "test/support/data/first_spend_txs.json" |> File.read!() |> Jason.decode!()
    %{raw: raw}
  end

  defp stamp(txid) do
    Repo.update_all(from(t in Transaction, where: t.txid == ^txid),
      set: [blob_stored_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end

  test "counts declared, stored and in-store txs, and names each gap" do
    # Blocks 9 and 170 are stored; 10..169 are missing headers.
    r = TxStore.reconcile(9, 170)

    assert {r.blocks, r.completed, r.declared, r.stored, r.in_store} == {2, 2, 3, 3, 0}
    assert {:blocks_missing, 160} in r.gaps
    assert {:txs_not_in_store, 3} in r.gaps
    refute Keyword.has_key?(r.gaps, :txs_not_stored)
  end

  test "every tx stored and uploaded is OK", %{raw: raw} do
    for {txid, hex} <- raw do
      :ok = TxStore.put(txid, Base.decode16!(hex, case: :mixed))
      stamp(txid)
    end

    r = TxStore.reconcile(170, 170)
    assert r.gaps == []
    assert {r.sampled, r.sample_bad} == {2, []}

    assert capture_io(fn -> Bitblocks.Release.tx_store_reconcile(170, 170) end) =~
             "OK: every declared tx is stored and in the store"
  end

  test "a tx stamped as stored whose object is missing is a mismatch, not a skip" do
    stamp(first_spend())
    # Never written to the store: the stamp is wrong.
    File.rm(Path.join(["tmp/tx_store_test", TxStore.key(first_spend())]))

    r = TxStore.reconcile(170, 170)
    assert r.sample_bad == [first_spend()]
    assert {:sample_mismatch, 1} in r.gaps

    out = capture_io(fn -> Bitblocks.Release.tx_store_reconcile(170, 170) end)
    assert out =~ "GAP sample_mismatch: 1"
    assert out =~ "mismatch: #{first_spend()}"
  end

  test "a tx the headers declare but we don't hold is counted" do
    Repo.delete_all(from(t in Transaction, where: t.txid == ^first_spend()))
    r = TxStore.reconcile(170, 170)
    assert {:txs_not_stored, 1} in r.gaps
  end
end
