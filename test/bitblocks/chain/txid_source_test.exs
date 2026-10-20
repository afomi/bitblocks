defmodule Bitblocks.Chain.TxidSourceTest do
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.TxidSource
  alias BitblocksWeb.RpcStub

  # Real mainnet block 170 (Satoshi → Hal Finney) — externally verifiable
  # txid/merkleroot pair, same fixture as merkle_verifier_test.exs.
  @block170_root "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff"
  @block170_txids [
    "b1fea52486ce0c62bb442b530a3f0132b826c74e473d1f2c220bfa78111c5082",
    "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"
  ]

  setup do
    RpcStub.setup()
    RpcStub.clear()
    :ok
  end

  describe "expected_tx_count/1" do
    test "prefers num_tx when positive" do
      block = block_fixture(%{num_tx: 7, tx: ["a", "b"]})
      assert TxidSource.expected_tx_count(block) == 7
    end

    test "falls back to the stored array length when num_tx is 0 or nil" do
      assert TxidSource.expected_tx_count(block_fixture(%{num_tx: 0, tx: ["a", "b"]})) == 2
      assert TxidSource.expected_tx_count(block_fixture(%{num_tx: nil, tx: ["a"]})) == 1
    end

    test "returns 0 when both are unknown" do
      assert TxidSource.expected_tx_count(block_fixture(%{num_tx: nil, tx: []})) == 0
    end
  end

  describe "txids/1 with a complete stored array" do
    test "returns the stored array without any RPC call" do
      block =
        block_fixture(%{num_tx: 2, tx: @block170_txids, merkleroot: @block170_root})

      assert {:ok, @block170_txids, ^block} = TxidSource.txids(block)
      assert RpcStub.calls() == []
    end

    test "fails closed when the stored array does not match the merkleroot" do
      poisoned = Enum.reverse(@block170_txids)

      block =
        block_fixture(%{num_tx: 2, tx: poisoned, merkleroot: @block170_root})

      assert {:error, {:merkleroot_verification_failed, :merkleroot_mismatch}} =
               TxidSource.txids(block)
    end
  end

  describe "txids/1 when the stored array is empty or short" do
    test "fetches the list from the node, verifies it, and self-heals the row" do
      block =
        block_fixture(%{num_tx: 2, tx: [], merkleroot: @block170_root})

      RpcStub.stub_getblock(block.hash, 1, %{"hash" => block.hash, "tx" => @block170_txids})

      assert {:ok, @block170_txids, healed} = TxidSource.txids(block)

      # Small block: the verified array is persisted for the next pass.
      assert healed.tx == @block170_txids
      assert healed.num_tx == 2
      assert Repo.reload!(block).tx == @block170_txids
    end

    test "corrects a wrong num_tx from the verified list" do
      block =
        block_fixture(%{num_tx: 5, tx: [], merkleroot: @block170_root})

      RpcStub.stub_getblock(block.hash, 1, %{"hash" => block.hash, "tx" => @block170_txids})

      assert {:ok, _txids, healed} = TxidSource.txids(block)
      assert healed.num_tx == 2
    end

    test "fails closed when the fetched list does not match the merkleroot" do
      block =
        block_fixture(%{num_tx: 2, tx: [], merkleroot: @block170_root})

      RpcStub.stub_getblock(block.hash, 1, %{
        "hash" => block.hash,
        "tx" => Enum.reverse(@block170_txids)
      })

      assert {:error, {:merkleroot_verification_failed, :merkleroot_mismatch}} =
               TxidSource.txids(block)
    end

    test "does not persist arrays above the 10k threshold but corrects num_tx" do
      # No merkleroot → verification is skipped (logged); this path exercises
      # only the persistence policy for huge blocks.
      block = block_fixture(%{num_tx: 0, tx: [], merkleroot: nil})
      huge = Enum.map(1..10_001, &("tx" <> Integer.to_string(&1)))

      RpcStub.stub_getblock(block.hash, 1, %{"hash" => block.hash, "tx" => huge})

      assert {:ok, ^huge, healed} = TxidSource.txids(block)
      assert healed.tx == []
      assert healed.num_tx == 10_001
      assert Repo.reload!(block).tx == []
    end

    test "propagates an RPC failure" do
      block = block_fixture(%{num_tx: 3, tx: []})

      assert {:error, {:no_stub, :getblock, _}} = TxidSource.txids(block)
    end

    test "errors when the node response has no txids" do
      block = block_fixture(%{num_tx: 3, tx: []})
      RpcStub.stub_getblock(block.hash, 1, %{"hash" => block.hash})

      assert {:error, :no_txids_in_block_response} = TxidSource.txids(block)
    end
  end
end
