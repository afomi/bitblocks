defmodule Bitblocks.Chain.RawBlockTest do
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain
  alias Bitblocks.Chain.RawBlock
  alias Bitblocks.Workers.FetchTransactionsWorker
  alias BitblocksWeb.RpcStub

  # The real genesis block: 285 bytes.
  @genesis_hash "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
  @genesis_merkleroot "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
  @genesis_hex "0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c" <>
                 "01" <>
                 "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

  setup do
    RpcStub.setup()
    RpcStub.clear()

    on_exit(fn ->
      Application.delete_env(:bitblocks, :raw_block_source)
      Application.delete_env(:bitblocks, :tx_fetch_run_ms)
    end)

    :ok
  end

  defp genesis_bytes, do: Base.decode16!(@genesis_hex, case: :lower)

  defp genesis_block(attrs \\ %{}) do
    block_fixture(
      Map.merge(
        %{
          height: 0,
          hash: @genesis_hash,
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [],
          sync_state: "header_only"
        },
        attrs
      )
    )
  end

  defp no_per_tx_calls! do
    assert RpcStub.calls(:getrawtransaction) == []
    assert RpcStub.calls(:batch_getrawtransaction) == []
    assert RpcStub.calls(:getblock) |> Enum.reject(&match?([_, 0], &1)) == []
  end

  describe "parse and check" do
    test "genesis splits into its coinbase, whose txid is the merkleroot" do
      bytes = genesis_bytes()
      assert byte_size(bytes) == 285
      assert {:ok, [{@genesis_merkleroot, tx}]} = RawBlock.parse(bytes)
      assert byte_size(tx) == 204
    end

    test "builds the getrawtransaction-shaped map TxIngest stores" do
      {:ok, [{txid, tx}]} = RawBlock.parse(genesis_bytes())
      json = RawBlock.tx_json(txid, tx)

      assert [%{"coinbase" => "04ffff001d01" <> _}] = json["vin"]

      assert [
               %{
                 "n" => 0,
                 "value" => 50.0,
                 "scriptPubKey" => %{
                   "type" => "pubkey",
                   "addresses" => ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]
                 }
               }
             ] = json["vout"]
    end

    test "a block from REST is checked against the header's merkleroot" do
      RpcStub.stub_rest_block(@genesis_hash, {:ok, genesis_bytes()})

      assert {:ok, [{@genesis_merkleroot, _}], %{source: :rest, bytes: 285}} =
               RawBlock.fetch(genesis_block())

      tampered = genesis_block(%{height: 1, hash: "x", merkleroot: String.duplicate("00", 32)})
      RpcStub.stub_rest_block("x", {:ok, genesis_bytes()})
      assert {:error, :block_hash_mismatch} = RawBlock.fetch(tampered)
    end

    test "a wrong merkleroot is refused" do
      RpcStub.stub_rest_block(@genesis_hash, {:ok, genesis_bytes()})
      block = genesis_block(%{merkleroot: String.duplicate("ab", 32)})

      assert {:error, {:merkleroot_verification_failed, _}} = RawBlock.fetch(block)
    end

    test "a REST 404 falls back to getblock(hash, 0)" do
      RpcStub.stub_rest_block(@genesis_hash, {:error, {:http_error, 404}})
      RpcStub.stub_getblock(@genesis_hash, 0, @genesis_hex)

      assert {:ok, [_], %{source: :rpc, bytes: 285}} = RawBlock.fetch(genesis_block())
    end

    test "source :rpc skips REST" do
      Application.put_env(:bitblocks, :raw_block_source, :rpc)
      RpcStub.stub_getblock(@genesis_hash, 0, @genesis_hex)

      assert {:ok, [_], %{source: :rpc}} = RawBlock.fetch(genesis_block())
      assert RpcStub.calls(:rest_block) == []
    end
  end

  describe "the block job on the raw path" do
    test "completes genesis from one request, with no per-tx RPC" do
      block = genesis_block()
      RpcStub.stub_rest_block(@genesis_hash, {:ok, genesis_bytes()})
      Phoenix.PubSub.subscribe(Bitblocks.PubSub, Bitblocks.SyncProgress.Tracker.topic())

      assert :ok = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      completed = Chain.get_block!(0)
      assert completed.sync_state == "completed"
      assert completed.size == 285
      tx = Chain.get_transaction!(@genesis_merkleroot)
      assert tx.output_addresses == ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]
      assert_receive {:sync_fetch, %{height: 0, bytes: 285, source: :rest}}
      no_per_tx_calls!()
    end

    test "a large block resumes mid-block by tx index across bounded runs" do
      Application.put_env(:bitblocks, :tx_fetch_run_ms, 0)
      {bytes, hash, merkleroot, txids} = synthetic_block(250)

      block =
        block_fixture(%{
          height: 0,
          hash: hash,
          merkleroot: merkleroot,
          num_tx: 250,
          tx: [],
          sync_state: "header_only"
        })

      RpcStub.stub_rest_block(hash, {:ok, bytes})
      {:ok, job} = Oban.insert(FetchTransactionsWorker.new(%{block_hash: block.hash}))

      assert {:snooze, _} = FetchTransactionsWorker.perform(Repo.reload!(job))
      assert Repo.reload!(job).meta["offset"] == 1
      assert Repo.aggregate(Chain.Transaction, :count) == 100

      assert {:snooze, _} = FetchTransactionsWorker.perform(Repo.reload!(job))
      assert :ok = FetchTransactionsWorker.perform(Repo.reload!(job))

      assert Chain.get_block!(0).sync_state == "completed"
      assert Repo.aggregate(Chain.Transaction, :count) == 250
      assert Enum.all?(txids, &Chain.get_transaction(&1))
      no_per_tx_calls!()
    end
  end

  # A structurally valid block of `n` one-in, one-out P2PKH txs, with a
  # correct merkleroot and hash.
  defp synthetic_block(n) do
    txs =
      for i <- 1..n do
        prev = :crypto.hash(:sha256, "prev-#{i}")
        pkh = binary_part(:crypto.hash(:sha256, "pkh-#{i}"), 0, 20)

        <<1::little-32, 1, prev::binary, 0::little-32, 0, 0xFFFFFFFF::little-32, 1, i::little-64,
          25, 0x76, 0xA9, 0x14, pkh::binary, 0x88, 0xAC, 0::little-32>>
      end

    leaves = Enum.map(txs, &sha256d/1)
    root = merkle(leaves)

    header =
      <<1::little-32, 0::256, root::binary, 1_231_006_505::little-32, 0x1D00FFFF::little-32,
        0::little-32>>

    count = if n < 0xFD, do: <<n>>, else: <<0xFD, n::little-16>>
    bytes = header <> count <> Enum.join(txs)

    {bytes, display(sha256d(header)), display(root), Enum.map(leaves, &display/1)}
  end

  defp merkle([root]), do: root

  defp merkle(level) do
    level
    |> Enum.chunk_every(2, 2, :discard)
    |> then(fn pairs ->
      pairs =
        if rem(length(level), 2) == 1,
          do: pairs ++ [[List.last(level), List.last(level)]],
          else: pairs

      Enum.map(pairs, fn [a, b] -> sha256d(a <> b) end)
    end)
    |> merkle()
  end

  defp sha256d(bin), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bin))

  defp display(bin),
    do:
      bin
      |> :binary.bin_to_list()
      |> Enum.reverse()
      |> :binary.list_to_bin()
      |> Base.encode16(case: :lower)
end
