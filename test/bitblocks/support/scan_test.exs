defmodule Bitblocks.Support.ScanTest do
  @moduledoc """
  The donation address's newest blocks, read by us (#74, option 3): the
  real genesis block pays 50 BSV to 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa, so
  it stands in for a block above the sync that holds a gift.
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Support
  alias Bitblocks.Support.{BlockScan, Scan}
  alias BitblocksWeb.RpcStub

  @address "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
  @genesis_hash "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
  @genesis_merkleroot "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
  @genesis_hex "0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c" <>
                 "01" <>
                 "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

  setup do
    RpcStub.setup()
    RpcStub.clear()
    original = Application.get_env(:bitblocks, :support)
    on_exit(fn -> Application.put_env(:bitblocks, :support, original) end)

    Application.put_env(:bitblocks, :support,
      monthly_costs: [],
      sponsor_url: nil,
      bsv_address: @address,
      scan_from_height: 0
    )

    RpcStub.stub_rest_block(@genesis_hash, {:ok, Base.decode16!(@genesis_hex, case: :lower)})
    :ok
  end

  # The genesis bytes, as a header-only block above complete_through.
  defp genesis_header(attrs \\ %{}) do
    block_fixture(
      Map.merge(
        %{
          height: 0,
          hash: @genesis_hash,
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          size: 285,
          tx: [],
          sync_state: "header_only"
        },
        attrs
      )
    )
  end

  test "reads a block above the sync once, and the support figures count its gift" do
    genesis_header()

    assert {:ok, %{read: 1, gift_sats: 5_000_000_000, stopped: :tip}} = Scan.run()
    assert %{from: 0, through: 0} = Scan.coverage(@address, -1)

    summary = Support.summary()
    assert summary.received_sats_total == 5_000_000_000
    assert summary.received_through_height == 0
    assert summary.received_pending_from_height == 1
    assert summary.received_note =~ "our own read of blocks 0 through 0 for this address"
    assert summary.received_note =~ "That is our tip."

    assert [
             %{source: "index", through_height: -1},
             %{source: "scan", from_height: 0, through_height: 0}
           ] = summary.received_sources

    # Caught up: the next run reads nothing.
    assert {:ok, %{read: 0, stopped: :tip}} = Scan.run()
    assert [_one] = Repo.all(BlockScan)
  end

  test "a block whose hash changed (a reorg) is read again, and the old row no longer counts" do
    genesis_header()
    {:ok, _} = Scan.run()

    Repo.update_all(BlockScan, set: [block_hash: "orphaned"])
    assert %{through: -1} = Scan.coverage(@address, -1)
    assert Support.summary().received_sats_total == 0

    assert {:ok, %{read: 1}} = Scan.run()
    assert Support.summary().received_sats_total == 5_000_000_000
  end

  test "a block over the raw-block cap streams, and its gift counts" do
    {:ok, %{pubkey_hash: pkh}} = BSV.Address.from_string(@address)
    big = Bitblocks.SyntheticBlock.build(33 * 1024 * 1024, pay_to: pkh, pay_sats: 70_000)
    RpcStub.stub_rest_block(big.hash, {:ok, big.bytes})

    block_fixture(%{
      height: 0,
      hash: big.hash,
      merkleroot: big.merkleroot,
      num_tx: length(big.txids),
      size: byte_size(big.bytes),
      tx: [],
      sync_state: "header_only"
    })

    assert Support.summary().received_note =~
             "Block 0 is next to read, streamed from our node for its size."

    assert {:ok, %{read: 1, gift_sats: 70_000, stopped: :tip}} = Scan.run()
    assert [%BlockScan{gift_txids: [gift_txid]}] = Repo.all(BlockScan)
    assert gift_txid == Enum.at(big.txids, 1)

    assert RpcStub.calls(:rest_block) == []
    assert RpcStub.calls(:rest_block_stream) == [[big.hash]]
    assert Support.summary().received_sats_total == 70_000
  end

  test "a streamed block that fails a check counts nothing, and the figures say why" do
    genesis_header(%{size: 64 * 1024 * 1024})
    bytes = Base.decode16!(@genesis_hex, case: :lower)
    RpcStub.stub_rest_block(@genesis_hash, {:ok, binary_part(bytes, 0, byte_size(bytes) - 1)})

    assert {:ok, %{read: 0, stopped: {0, {:truncated, 284}}}} = Scan.run()
    assert [%BlockScan{status: "failed", attempts: 1, gift_sats: 0}] = Repo.all(BlockScan)
    assert %{through: -1} = Scan.coverage(@address, -1)

    # Tried again only after the backoff: 1 minute after the first failure.
    assert {:ok, %{read: 0, stopped: {0, {:backing_off, _until}}}} = Scan.run()
    Repo.update_all(BlockScan, set: [scanned_at: ~U[2020-01-01 00:00:00Z]])

    # REST off: no fallback for a block this size.
    RpcStub.stub_rest_block(@genesis_hash, {:error, {:http_error, 404}})
    assert {:ok, %{read: 0, stopped: {0, {:http_error, 404}}}} = Scan.run()
    assert RpcStub.calls(:getblock) == []

    summary = Support.summary()
    assert summary.received_sats_total == 0
    assert summary.received_note =~ "Block 0 couldn't be read yet ({:http_error, 404}; 2 tries"
    assert summary.received_note =~ "the next try is at"

    RpcStub.stub_rest_block(@genesis_hash, {:ok, bytes})
    Repo.update_all(BlockScan, set: [scanned_at: ~U[2020-01-01 00:00:00Z]])
    assert {:ok, %{read: 1, gift_sats: 5_000_000_000}} = Scan.run()
    assert [%BlockScan{status: "read", error: nil, attempts: 0}] = Repo.all(BlockScan)
  end

  test "a header with no size and few txs, over the cap, streams; getblock is never asked" do
    # Block 971,525 in miniature: 367 txs looked small, the block was 145.9 MB.
    genesis_header(%{size: nil, num_tx: 1})
    Application.put_env(:bitblocks, :raw_block_max_bytes, 100)
    on_exit(fn -> Application.delete_env(:bitblocks, :raw_block_max_bytes) end)

    assert {:ok, %{read: 1, gift_sats: 5_000_000_000}} = Scan.run()
    assert RpcStub.calls(:rest_block) == [[@genesis_hash]]
    assert RpcStub.calls(:rest_block_stream) == [[@genesis_hash]]
    assert RpcStub.calls(:getblock) == []
  end

  test "failed reads back off 1, 2, 4 ... minutes, capped at an hour" do
    at = ~U[2026-11-11 22:00:00Z]

    for {n, minutes} <- [{1, 1}, {2, 2}, {3, 4}, {7, 60}, {30, 60}] do
      scan = %BlockScan{status: "failed", attempts: n, scanned_at: at}
      assert Scan.next_try(scan) == DateTime.add(at, minutes * 60, :second)
    end

    assert Scan.next_try(%BlockScan{status: "read"}) == nil
  end

  test "a block that fails to fetch counts nothing, and its reason is kept" do
    genesis_header(%{hash: "elsewhere"})
    RpcStub.stub_rest_block("elsewhere", {:ok, Base.decode16!(@genesis_hex, case: :lower)})

    assert {:ok, %{read: 0, stopped: {0, :block_hash_mismatch}}} = Scan.run()
    assert [%BlockScan{status: "failed", error: ":block_hash_mismatch"}] = Repo.all(BlockScan)
    assert Scan.gifts(@address, 0, 0) == 0
  end

  test "a block left mid-read (a deploy) says it is being read, and still counts nothing" do
    block = genesis_header()

    Repo.insert!(%BlockScan{
      height: 0,
      block_hash: block.hash,
      address: @address,
      status: "reading",
      started_at: ~U[2026-11-11 22:00:00Z],
      scanned_at: ~U[2026-11-11 22:00:00Z]
    })

    assert Scan.stop_reason(-1, @address) =~
             "Block 0 is being read now, streamed from our node, since 22:00 UTC."

    assert %{through: -1} = Scan.coverage(@address, -1)
  end

  test "nothing is read before scan_from_height, nor without it" do
    genesis_header()

    assert {:ok, %{stopped: :not_configured}} = Scan.run(since: nil)
    assert {:ok, %{read: 0, stopped: :tip}} = Scan.run(since: 1)
    assert Repo.all(BlockScan) == []
  end
end
