defmodule Bitblocks.Chain.BlockImportTest do
  # Raw blocks exported from our node as files (<height>-<hash>.bin) import
  # through the same checks and storage as the sync loop, with no node calls.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{Block, BlockImport, Transaction}
  alias BitblocksWeb.RpcStub

  @genesis_hash "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
  @genesis_txid "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
  @genesis_hex "0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c" <>
                 "01" <>
                 "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

  setup do
    RpcStub.setup()
    RpcStub.clear()
    :ok
  end

  defp write_genesis(dir, name \\ "0-#{@genesis_hash}.bin") do
    File.write!(Path.join(dir, name), Base.decode16!(@genesis_hex, case: :lower))
  end

  @tag :tmp_dir
  test "imports a block file with no header row and no node calls", %{tmp_dir: dir} do
    write_genesis(dir)

    assert {:ok, report} = BlockImport.import_dir(dir)
    assert report.completed == [0]
    assert report.failed == []

    block = Repo.get_by!(Block, height: 0)
    assert block.hash == @genesis_hash
    assert block.merkleroot == @genesis_txid
    # Genesis has no predecessor; header sync stores "" for it too.
    assert block.prevblockhash == ""
    assert block.num_tx == 1
    assert block.size == 285
    assert block.sync_state == "completed"

    assert Repo.get_by!(Transaction, txid: @genesis_txid).block_hash == @genesis_hash
    assert RpcStub.calls() == []
  end

  @tag :tmp_dir
  test "a file whose bytes aren't the named block is refused", %{tmp_dir: dir} do
    other = String.duplicate("ab", 32)
    write_genesis(dir, "0-#{other}.bin")

    assert {:ok, report} = BlockImport.import_dir(dir)
    assert [{0, :block_hash_mismatch}] = report.failed
    refute Repo.get_by(Block, height: 0)
    refute Repo.get_by(Transaction, txid: @genesis_txid)
  end

  @tag :tmp_dir
  test "a height already held by a different block is reported, not overwritten", %{
    tmp_dir: dir
  } do
    block_fixture(%{height: 0, hash: "some_other_block"})
    write_genesis(dir)

    assert {:ok, report} = BlockImport.import_dir(dir)
    assert [{0, {:height_taken, "some_other_block"}}] = report.failed
    assert Repo.get_by!(Block, height: 0).hash == "some_other_block"
  end

  @tag :tmp_dir
  test "importing again changes nothing", %{tmp_dir: dir} do
    write_genesis(dir)
    {:ok, _} = BlockImport.import_dir(dir)

    assert {:ok, report} = BlockImport.import_dir(dir)
    assert report.already_complete == [0]
    assert Repo.aggregate(Transaction, :count) == 1
  end
end
