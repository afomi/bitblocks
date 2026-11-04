defmodule Bitblocks.TxStore.BlockObjectTest do
  @moduledoc """
  Every completed block's exact bytes in the tx store as one object, each tx
  located in it, and served back by range (docs/TX_STORAGE.md, steps 1 and 2).
  Built from the real block 170: its header fields and its two real txs (the
  coinbase, then Satoshi's first spend to Hal Finney).
  """
  # async: false: the RPC stub table, the store directory and app env are global.
  use BitblocksWeb.ConnCase, async: false

  import Ecto.Query
  import Bitblocks.ChainFixtures
  import Bitblocks.FirstSpendFixtures, only: [coinbase_170: 0, first_spend: 0]
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.{Repo, TxStore}
  alias Bitblocks.TxStore.BlockObject
  alias Bitblocks.Workers.FetchTransactionsWorker
  alias BitblocksWeb.RpcStub

  @hash "00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee"
  @prev "000000002a22cfee1f2c846adbd12b3e183d4f97683f85dad08a79780a84bd55"
  @merkleroot "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff"
  @root "tmp/tx_store_test"

  # A store that says every put worked and keeps nothing: the write must be
  # verified, never taken on the put's word.
  defmodule Forgetful do
    @behaviour Bitblocks.TxStore
    def put(_key, _bytes), do: :ok
    def get(_key), do: {:error, :not_found}
    def size(_key), do: {:error, :not_found}
    def get_range(_key, _offset, _length), do: {:error, :not_found}
    def public_url(_key), do: nil
    def ready?, do: :ok
  end

  setup do
    RpcStub.setup()
    RpcStub.clear()
    File.rm(Path.join(@root, BlockObject.key(170, @hash)))

    on_exit(fn ->
      Application.delete_env(:bitblocks, :store_block_objects)
      File.rm(Path.join(@root, BlockObject.key(170, @hash)))
    end)

    raw = "test/support/data/first_spend_txs.json" |> File.read!() |> Jason.decode!()
    %{raw: raw, bytes: block_170_bytes(raw)}
  end

  defp block_170_bytes(raw) do
    header =
      <<1::little-32, rev(@prev)::binary, rev(@merkleroot)::binary, 1_231_731_025::little-32,
        0x1D00FFFF::little-32, 1_889_418_792::little-32>>

    txs = [coinbase_170(), first_spend()] |> Enum.map(&Base.decode16!(raw[&1], case: :lower))
    header <> <<2>> <> Enum.join(txs)
  end

  defp rev(hex),
    do:
      hex
      |> Base.decode16!(case: :lower)
      |> :binary.bin_to_list()
      |> Enum.reverse()
      |> :binary.list_to_bin()

  defp block_170 do
    block_fixture(%{
      height: 170,
      hash: @hash,
      prevblockhash: @prev,
      merkleroot: @merkleroot,
      num_tx: 2,
      size: nil,
      tx: [],
      sync_state: "header_only"
    })
  end

  defp sync_170(bytes) do
    block = block_170()
    RpcStub.stub_rest_block(@hash, {:ok, bytes})
    assert :ok = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => @hash}})
    block
  end

  defp clear_db_raw(txid),
    do: Repo.update_all(from(t in Transaction, where: t.txid == ^txid), set: [raw: nil])

  test "the header built from the fixture is block 170's", %{bytes: bytes} do
    assert TxStore.txid(binary_part(bytes, 0, 80)) == @hash
  end

  describe "the block job" do
    test "writes the block's bytes, verifies them, and locates each tx", %{bytes: bytes} do
      sync_170(bytes)

      block = Repo.get_by!(Block, hash: @hash)
      assert block.sync_state == "completed"
      assert %DateTime{} = block.raw_object_stored_at
      assert File.read!(Path.join(@root, "blocks/170-#{@hash}.bin")) == bytes

      coinbase = Repo.get_by!(Transaction, txid: coinbase_170())
      spend = Repo.get_by!(Transaction, txid: first_spend())

      # 80-byte header, then a one-byte tx count: the coinbase starts at 81
      # and the spend straight after it.
      assert coinbase.raw_offset == 81
      assert spend.raw_offset == 81 + coinbase.raw_length
      assert spend.raw_offset + spend.raw_length == byte_size(bytes)

      for tx <- [coinbase, spend] do
        assert TxStore.txid(binary_part(bytes, tx.raw_offset, tx.raw_length)) == tx.txid
      end
    end

    test "a write the store didn't keep leaves the block completed and unstamped",
         %{bytes: bytes} do
      previous = Application.get_env(:bitblocks, TxStore)
      Application.put_env(:bitblocks, TxStore, adapter: Forgetful)
      on_exit(fn -> Application.put_env(:bitblocks, TxStore, previous) end)

      log = capture_log(fn -> sync_170(bytes) end)

      block = Repo.get_by!(Block, hash: @hash)
      assert block.sync_state == "completed"
      assert block.raw_object_stored_at == nil
      assert log =~ "not stored"
      assert Repo.get_by!(Transaction, txid: first_spend()).raw_offset == nil
    end

    test "writes nothing when turned off", %{bytes: bytes} do
      Application.put_env(:bitblocks, :store_block_objects, false)
      sync_170(bytes)

      assert Repo.get_by!(Block, hash: @hash).sync_state == "completed"
      assert Repo.get_by!(Block, hash: @hash).raw_object_stored_at == nil
      refute File.exists?(Path.join(@root, BlockObject.key(170, @hash)))
    end
  end

  describe "the backfill" do
    setup %{bytes: bytes} do
      Application.put_env(:bitblocks, :store_block_objects, false)
      sync_170(bytes)
      Application.delete_env(:bitblocks, :store_block_objects)
      RpcStub.clear()
      :ok
    end

    test "dry run counts the block and touches neither the node nor the store", %{bytes: bytes} do
      RpcStub.stub_rest_block(@hash, {:ok, bytes})

      out = capture_io(fn -> Bitblocks.Release.store_block_objects(0, 1_000) end)

      assert out =~ "DRY RUN"
      assert out =~ "1 completed block(s) without an object"
      assert RpcStub.calls(:rest_block) == []
      assert Repo.get_by!(Block, hash: @hash).raw_object_stored_at == nil
    end

    test "apply refetches, writes, verifies and stamps; a rerun finds nothing",
         %{bytes: bytes} do
      RpcStub.stub_rest_block(@hash, {:ok, bytes})

      r = BlockObject.backfill(0, 1_000, apply: true)
      assert {r.missing, r.attempted, r.stored, r.failed} == {1, 1, 1, 0}
      assert %DateTime{} = Repo.get_by!(Block, hash: @hash).raw_object_stored_at
      assert Repo.get_by!(Transaction, txid: first_spend()).raw_offset != nil

      assert %{missing: 0, attempted: 0} = BlockObject.backfill(0, 1_000, apply: true)
    end

    test "a node refusing RPC fails cleanly and says so" do
      RpcStub.stub_rest_block(@hash, {:error, :econnrefused})
      RpcStub.stub_getblock(@hash, 0, {:error, :econnrefused})

      out =
        capture_io(fn ->
          capture_log(fn ->
            send(self(), {:r, Bitblocks.Release.store_block_objects(0, 1_000, apply: true)})
          end)
        end)

      assert_received {:r, r}
      assert {r.attempted, r.stored, r.failed} == {1, 0, 1}
      assert [{170, {:fetch, :econnrefused}}] = r.failures
      assert out =~ "FAILED 170"
      assert Repo.get_by!(Block, hash: @hash).raw_object_stored_at == nil
    end

    test "a block over the raw-block cap is counted, never fetched" do
      Repo.update_all(from(b in Block, where: b.hash == ^@hash), set: [size: 64 * 1024 * 1024])

      r = BlockObject.backfill(0, 1_000, apply: true)
      assert {r.missing, r.too_large, r.attempted} == {1, 1, 0}
      assert RpcStub.calls(:rest_block) == []
    end
  end

  describe "reading a tx back from its block's object" do
    setup %{bytes: bytes} do
      sync_170(bytes)
      :ok
    end

    test "raw/1 takes a ranged read when the database holds no raw", %{raw: raw} do
      clear_db_raw(first_spend())

      assert {:ok, bytes} = TxStore.raw(first_spend())
      assert bytes == Base.decode16!(raw[first_spend()], case: :lower)
      assert TxStore.txid(bytes) == first_spend()
    end

    test "raw/1 refuses a range whose bytes don't hash to the txid" do
      clear_db_raw(first_spend())

      Repo.update_all(from(t in Transaction, where: t.txid == ^first_spend()),
        set: [raw_offset: 81]
      )

      assert {:error, :bytes_do_not_hash_to_txid} = TxStore.raw(first_spend())
    end

    test "GET /api/v1/txs/:txid/raw serves the verified bytes, immutable", %{conn: conn} do
      clear_db_raw(first_spend())

      conn = get(conn, "/api/v1/txs/#{first_spend()}/raw")

      assert conn.status == 200
      assert TxStore.txid(conn.resp_body) == first_spend()
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "GET /api/v1/txs/:txid/raw answers octet-stream clients too", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/octet-stream")
        |> get("/api/v1/txs/#{coinbase_170()}/raw")

      assert conn.status == 200
      assert TxStore.txid(conn.resp_body) == coinbase_170()
    end

    test "an unknown or malformed txid is an error that isn't cached", %{conn: conn} do
      unknown = get(conn, "/api/v1/txs/#{String.duplicate("ab", 32)}/raw")
      assert unknown.status == 404
      assert get_resp_header(unknown, "cache-control") == ["no-store"]

      assert get(conn, "/api/v1/txs/nope/raw").status == 400
    end

    test "bytes that don't hash to the txid are never served", %{conn: conn} do
      Repo.update_all(from(t in Transaction, where: t.txid == ^first_spend()),
        set: [raw: "00"]
      )

      log =
        capture_log(fn ->
          send(self(), {:resp, get(conn, "/api/v1/txs/#{first_spend()}/raw")})
        end)

      assert_received {:resp, resp}
      assert resp.status == 500
      assert get_resp_header(resp, "cache-control") == ["no-store"]
      assert log =~ "held bytes refused"
    end
  end

  describe "reconcile" do
    test "counts block objects stored and missing, and txs located in them",
         %{bytes: bytes} do
      sync_170(bytes)

      r = TxStore.reconcile(170, 170)
      assert {r.completed, r.block_objects, r.block_objects_missing} == {1, 1, 0}
      assert {r.stored, r.in_store, r.in_block_objects} == {2, 2, 2}
      assert r.range_sampled == 2
      assert r.sample_bad == []
      assert r.gaps == []

      out = capture_io(fn -> Bitblocks.Release.tx_store_reconcile(170, 170) end)
      assert out =~ "block objects     1 stored, 0 missing"
      assert out =~ "OK: every declared tx is stored and in the store"
    end

    test "a block without an object is a gap, and its txs aren't in the store",
         %{bytes: bytes} do
      Application.put_env(:bitblocks, :store_block_objects, false)
      sync_170(bytes)

      r = TxStore.reconcile(170, 170)
      assert {:block_objects_missing, 1} in r.gaps
      assert {:txs_not_in_store, 2} in r.gaps
    end

    test "an object gone from the store is a sample mismatch, not a skip", %{bytes: bytes} do
      sync_170(bytes)
      File.rm!(Path.join(@root, BlockObject.key(170, @hash)))

      r = TxStore.reconcile(170, 170)
      assert {:sample_mismatch, 2} in r.gaps
    end
  end
end
