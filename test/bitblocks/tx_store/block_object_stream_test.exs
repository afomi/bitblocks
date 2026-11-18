defmodule Bitblocks.TxStore.BlockObjectStreamTest do
  @moduledoc """
  A block over the raw-block cap given its object by multipart upload
  (https://github.com/afomi/bitblocks/issues/86): streamed from node REST
  (`Chain.BlockStream`) into parts of at least 5 MiB, verified, then
  stamped; any failure aborts the upload and leaves the block unstamped.

  The cap is lowered to 100 KB, so a synthetic block of about 11 MB
  (`Bitblocks.SyntheticBlock`) is over it, and the part size is S3's
  smallest, 5 MiB, so the block spans three parts.
  The store is the Local adapter, seen through `Recording`, which reports
  each multipart call to the test.
  """
  # async: false: the RPC stub table, the store directory and app env are global.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import ExUnit.CaptureLog

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.{SyntheticBlock, TxStore}
  alias Bitblocks.TxStore.{BlockObject, BlockObjectsBackfill, Local}
  alias BitblocksWeb.RpcStub

  @cap 100_000
  @root "tmp/tx_store_test"
  @height 600_123

  # The Local store, reporting every multipart call to the test process.
  # `:recording_faults` in app env injects failures: `{:part, n}` (an error
  # on part n), `{:raise_part, n}` (an exception there), `:complete` and
  # `:abort` (errors on those calls).
  defmodule Recording do
    @behaviour Bitblocks.TxStore

    defp report(msg), do: send(Application.fetch_env!(:bitblocks, :recording_pid), msg)
    defp fault?(f), do: f in Application.get_env(:bitblocks, :recording_faults, [])

    defdelegate put(key, bytes), to: Local
    defdelegate get(key), to: Local
    defdelegate size(key), to: Local
    defdelegate get_range(key, offset, length), to: Local
    defdelegate public_url(key), to: Local
    defdelegate ready?(), to: Local

    def multipart_start(key) do
      report({:start, key})
      Local.multipart_start(key)
    end

    def multipart_put_part(upload, number, bytes) do
      report({:part, number, byte_size(bytes)})

      cond do
        fault?({:raise_part, number}) -> raise "injected part failure"
        fault?({:part, number}) -> {:error, :injected}
        true -> Local.multipart_put_part(upload, number, bytes)
      end
    end

    def multipart_complete(upload, parts) do
      report({:complete, length(parts)})
      if fault?(:complete), do: {:error, :injected}, else: Local.multipart_complete(upload, parts)
    end

    def multipart_abort(upload) do
      report({:abort, upload.dir})
      if fault?(:abort), do: {:error, :injected}, else: Local.multipart_abort(upload)
    end
  end

  setup_all do
    # About 11 MB: three parts of 5 MiB, the last shorter.
    %{big: SyntheticBlock.build(11_000_000)}
  end

  setup %{big: big} do
    RpcStub.setup()
    RpcStub.clear()

    saved_cap = Application.fetch_env(:bitblocks, :raw_block_max_bytes)
    saved_store = Application.fetch_env!(:bitblocks, TxStore)
    Application.put_env(:bitblocks, :raw_block_max_bytes, @cap)
    # S3's smallest part, rather than the 16 MiB default.
    Application.put_env(:bitblocks, :block_object_part_bytes, TxStore.min_part_bytes())
    Application.put_env(:bitblocks, TxStore, Keyword.put(saved_store, :adapter, Recording))
    Application.put_env(:bitblocks, :recording_pid, self())

    key = BlockObject.key(@height, big.hash)
    File.rm_rf!(Path.join(@root, "blocks"))

    on_exit(fn ->
      case saved_cap do
        {:ok, v} -> Application.put_env(:bitblocks, :raw_block_max_bytes, v)
        :error -> Application.delete_env(:bitblocks, :raw_block_max_bytes)
      end

      Application.put_env(:bitblocks, TxStore, saved_store)
      Application.delete_env(:bitblocks, :block_object_part_bytes)
      Application.delete_env(:bitblocks, :recording_pid)
      Application.delete_env(:bitblocks, :recording_faults)
      File.rm_rf!(Path.join(@root, "blocks"))
    end)

    block =
      block_fixture(%{
        height: @height,
        hash: big.hash,
        merkleroot: big.merkleroot,
        num_tx: length(big.txids),
        size: byte_size(big.bytes),
        tx: [],
        sync_state: "completed"
      })

    # Rows for a few of its txs, as the sync's stream path leaves them: no
    # offsets. The first, one in the middle (well past the first part), and
    # the last.
    picked = [hd(big.txids), Enum.at(big.txids, div(length(big.txids), 2)), List.last(big.txids)]

    for txid <- picked do
      transaction_fixture(%{txid: txid, block_hash: big.hash, block_height: @height})
    end

    %{block: block, key: key, picked: picked}
  end

  defp object_path(key), do: Path.join(@root, key)

  defp leftover_parts,
    do: Path.wildcard(Path.join(@root, "blocks/*.multipart-*"))

  defp stamped?(hash), do: Repo.get_by!(Block, hash: hash).raw_object_stored_at != nil

  defp parts_received(acc \\ []) do
    receive do
      {:part, n, size} -> parts_received([{n, size} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A byte inside the last 70 KB OP_RETURN, changed: the header still hashes
  # to the block's hash and every tx parses, but the merkleroot can't
  # rebuild, which the stream knows only at the very end, after every part.
  defp tamper_near_end(bytes) do
    marker = :binary.copy(<<0x42>>, 1_000)
    {at, _} = bytes |> :binary.matches(marker) |> List.last()
    <<head::binary-size(at), _byte, tail::binary>> = bytes
    <<head::binary, 0x43, tail::binary>>
  end

  test "a large block goes up in several parts, verifies, and every row is located",
       %{big: big, block: block, key: key, picked: picked} do
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

    assert {:ok, result} = BlockObject.fetch_and_store(block)

    # Streamed, never fetched whole.
    assert RpcStub.calls(:rest_block_stream) == [[big.hash]]
    assert RpcStub.calls(:rest_block) == []

    assert_received {:start, ^key}
    parts = parts_received()
    assert length(parts) == 3
    assert result.parts == 3
    assert Enum.map(parts, &elem(&1, 0)) == [1, 2, 3]
    {full, [_last]} = Enum.split(Enum.map(parts, &elem(&1, 1)), -1)
    assert Enum.all?(full, &(&1 >= TxStore.min_part_bytes()))
    assert Enum.sum(Enum.map(parts, &elem(&1, 1))) == byte_size(big.bytes)
    assert_received {:complete, 3}
    refute_received {:abort, _}

    # The object is the block's exact bytes, and the block is stamped.
    assert File.read!(object_path(key)) == big.bytes
    assert stamped?(big.hash)
    assert result.bytes == byte_size(big.bytes)
    assert leftover_parts() == []

    # Each row points at its own bytes in the object, and reads back by range.
    assert result.located == length(picked)

    for txid <- picked do
      tx = Repo.get_by!(Transaction, txid: txid)
      assert TxStore.txid(binary_part(big.bytes, tx.raw_offset, tx.raw_length)) == txid
      Repo.update_all(from(t in Transaction, where: t.txid == ^txid), set: [raw: nil])
      assert {:ok, bytes} = TxStore.raw(txid)
      assert TxStore.txid(bytes) == txid
    end

    first = Repo.get_by!(Transaction, txid: hd(big.txids))
    # 80-byte header, then the tx count's 0xFD varint.
    assert first.raw_offset == 83
  end

  test "a connection lost mid-stream aborts the upload and leaves the block unstamped",
       %{big: big, block: block, key: key, picked: picked} do
    # Seven MB, then the node drops the connection: one part is up by then.
    RpcStub.stub_rest_block(big.hash, {:partial, binary_part(big.bytes, 0, 7_000_000), :closed})

    log =
      capture_log(fn ->
        assert {:error, {{:connection_error, :closed}, _}} = BlockObject.store_streamed(block)
      end)

    assert log =~ "not stored"
    assert [{1, _}] = parts_received()
    assert_received {:abort, _dir}
    refute_received {:complete, _}

    refute stamped?(big.hash)
    refute File.exists?(object_path(key))
    assert leftover_parts() == []

    # An offset written before the drop is never read: the block is unstamped.
    txid = hd(picked)
    Repo.update_all(from(t in Transaction, where: t.txid == ^txid), set: [raw: nil])
    assert {:error, _} = TxStore.raw(txid)
  end

  test "bytes that fail the merkleroot abort the upload after every part",
       %{big: big, block: block, key: key} do
    RpcStub.stub_rest_block(big.hash, {:ok, tamper_near_end(big.bytes)})

    capture_log(fn ->
      assert {:error, {:merkleroot_verification_failed, :merkleroot_mismatch}} =
               BlockObject.store_streamed(block)
    end)

    # The last part was never sent: the root fails before the final flush.
    assert length(parts_received()) == 2
    assert_received {:abort, _dir}
    refute_received {:complete, _}
    refute stamped?(big.hash)
    refute File.exists?(object_path(key))
    assert leftover_parts() == []
  end

  test "an object already in the store with the block's size is kept and verified",
       %{big: big, block: block, key: key, picked: picked} do
    File.mkdir_p!(Path.dirname(object_path(key)))
    File.write!(object_path(key), big.bytes)
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

    assert {:ok, %{parts: 0, located: located}} = BlockObject.store_streamed(block)
    assert located == length(picked)
    refute_received {:start, _}
    assert stamped?(big.hash)
  end

  describe "a failing write" do
    defp fail_with(faults), do: Application.put_env(:bitblocks, :recording_faults, faults)

    defp store_failing(block) do
      capture_log(fn -> send(self(), {:result, BlockObject.store_streamed(block)}) end)
      assert_received {:result, result}
      result
    end

    defp left_clean!(big, key) do
      refute stamped?(big.hash)
      refute File.exists?(object_path(key))
      assert leftover_parts() == []
    end

    test "a part the store refuses aborts the upload", %{big: big, block: block, key: key} do
      fail_with([{:part, 2}])
      RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

      assert {:error, {:upload_part, 2, :injected}} = store_failing(block)
      assert_received {:abort, _dir}
      refute_received {:complete, _}
      left_clean!(big, key)
    end

    test "an exception in a part upload aborts the upload", %{big: big, block: block, key: key} do
      fail_with([{:raise_part, 1}])
      RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

      assert {:error, {:upload_part, 1, {:exception, "injected part failure"}}} =
               store_failing(block)

      assert_received {:abort, _dir}
      refute_received {:complete, _}
      left_clean!(big, key)
    end

    test "a completion the store refuses aborts and leaves nothing at the key",
         %{big: big, block: block, key: key} do
      fail_with([:complete])
      RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

      assert {:error, {:multipart_complete, :injected}} = store_failing(block)
      assert length(parts_received()) == 3
      assert_received {:complete, 3}
      assert_received {:abort, _dir}
      left_clean!(big, key)
    end

    test "a failed abort is returned with the error", %{big: big, block: block, key: key} do
      fail_with([{:part, 1}, :abort])
      RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

      assert {:error, {{:upload_part, 1, :injected}, abort: :injected}} = store_failing(block)
      assert_received {:abort, _dir}
      refute stamped?(big.hash)
      refute File.exists?(object_path(key))
    end
  end

  describe "the block_objects backfill" do
    test "with large_blocks: true, streams a block over the cap and stamps it",
         %{big: big, key: key} do
      RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

      dry = BlockObjectsBackfill.run(@height, @height, large_blocks: true)
      assert dry.details.too_large == 1
      assert dry.details.eligible == 1
      assert dry.rows_changed == 1
      assert RpcStub.calls(:rest_block_stream) == []

      applied = BlockObjectsBackfill.run(@height, @height, apply: true, large_blocks: true)
      assert applied.details.too_large == 1
      assert applied.details.stored == 1
      assert applied.rows_below_version == 0
      assert stamped?(big.hash)
      assert File.read!(object_path(key)) == big.bytes
    end

    test "by default, counts it and leaves it", %{big: big} do
      r = BlockObjectsBackfill.run(@height, @height, apply: true)
      assert r.details.too_large == 1
      assert {r.details.eligible, r.details.stored} == {0, 0}
      assert RpcStub.calls(:rest_block_stream) == []
      refute stamped?(big.hash)
    end

    test "a small-looking block the node refuses whole is streamed and counted too_large",
         %{big: big, key: key} do
      # No stored size and a few thousand txs: eligible for a whole fetch,
      # which the node refuses as over the cap.
      Repo.update_all(from(b in Block, where: b.hash == ^big.hash), set: [size: nil])
      RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

      r = BlockObjectsBackfill.run(@height, @height, apply: true, large_blocks: true)
      assert {r.details.too_large, r.details.stored} == {1, 1}
      assert RpcStub.calls(:rest_block) == [[big.hash]]
      assert RpcStub.calls(:rest_block_stream) == [[big.hash]]
      assert File.read!(object_path(key)) == big.bytes

      # Release.store_block_objects/3 never streams.
      Repo.update_all(from(b in Block, where: b.hash == ^big.hash),
        set: [raw_object_stored_at: nil]
      )

      RpcStub.clear()
      RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

      capture_log(fn ->
        send(self(), {:r, BlockObject.backfill(@height, @height, apply: true)})
      end)

      assert_received {:r, %{failed: 1, failures: [{@height, {:fetch, :block_too_large}}]}}
      assert RpcStub.calls(:rest_block_stream) == []
    end

    test "large blocks failing one after another stop the range at max_failures" do
      # Three more large blocks, each refused by REST: one per batch, since a
      # batch ends after each streamed block, so the count must carry over.
      for i <- 1..3 do
        block_fixture(%{
          height: @height + i,
          num_tx: 10,
          size: 50_000_000,
          tx: [],
          sync_state: "completed"
        })
      end

      log =
        capture_log(fn ->
          send(
            self(),
            {:r,
             BlockObjectsBackfill.run(@height + 1, @height + 10,
               apply: true,
               large_blocks: true
             )}
          )
        end)

      assert_received {:r, r}
      assert r.outcome == "partial"
      assert r.error =~ "3 block object failures in a row"
      # The third failure raises, so the run keeps the report up to the second.
      assert r.details.failed == 2
      assert log =~ "not stored"
    end
  end
end
