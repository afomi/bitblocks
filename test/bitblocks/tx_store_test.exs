defmodule Bitblocks.TxStoreTest do
  @moduledoc """
  Raw tx bytes in a blob store keyed by txid: only true bytes are written, a
  write is confirmed before it's recorded, and reads fall back from the
  database to the blob store.
  """
  use Bitblocks.DataCase, async: true
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.Chain.Transaction
  alias Bitblocks.{OrdinalCollections, TxStore}
  alias Bitblocks.Workers.StoreTxBlobWorker

  setup do
    {txid, hex} = built = tx([funding_outpoint()], [p2pkh(address(), 5_000)])
    publish(built)
    %{txid: txid, bytes: Base.decode16!(hex, case: :mixed)}
  end

  test "put/2 refuses bytes that don't hash to the txid", ctx do
    assert {:error, :bytes_do_not_hash_to_txid} = TxStore.put(ctx.txid, ctx.bytes <> <<0>>)
    assert {:error, :not_found} = TxStore.raw(ctx.txid)
  end

  test "store/1 writes, verifies, then records blob_stored_at", ctx do
    OrdinalCollections.import_txs([ctx.txid])
    assert Repo.get_by!(Transaction, txid: ctx.txid).blob_stored_at == nil

    assert :ok = TxStore.store(ctx.txid)

    tx = Repo.get_by!(Transaction, txid: ctx.txid)
    assert %DateTime{} = tx.blob_stored_at
    assert {:ok, %{bad: []}} = {:ok, TxStore.verify_sample(5)}
  end

  test "raw/1 falls back to the blob store when the database has no copy", ctx do
    assert :ok = TxStore.put(ctx.txid, ctx.bytes)
    refute Repo.get_by(Transaction, txid: ctx.txid)
    assert {:ok, bytes} = TxStore.raw(ctx.txid)
    assert bytes == ctx.bytes
  end

  test "importing a tx for a collection enqueues its blob write", ctx do
    OrdinalCollections.import_txs([ctx.txid])
    assert_enqueued(worker: StoreTxBlobWorker, args: %{"txid" => ctx.txid})

    # Once stored, it isn't enqueued again.
    :ok = TxStore.store(ctx.txid)
    assert TxStore.enqueue([ctx.txid]) == 0
  end

  test "url/1 is nil until stored, and nil without a CDN (local adapter)", ctx do
    OrdinalCollections.import_txs([ctx.txid])
    assert TxStore.url(Repo.get_by!(Transaction, txid: ctx.txid)) == nil
  end

  describe "the S3 adapter without a bucket" do
    @tag skip: System.get_env("AWS_S3_BUCKET_TXS") != nil
    test "isn't ready, and says why" do
      assert {:error, :no_bucket_configured} = Bitblocks.TxStore.S3.ready?()
    end
  end
end
