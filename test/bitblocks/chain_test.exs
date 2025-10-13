defmodule Bitblocks.ChainTest do
  use Bitblocks.DataCase

  alias Bitblocks.Chain

  describe "blocks" do
    alias Bitblocks.Chain.Block

    import Bitblocks.ChainFixtures

    @invalid_attrs %{
      size: nil,
      hash: nil,
      height: nil
    }

    test "list_blocks/0 returns all blocks" do
      block = block_fixture()
      assert Chain.list_blocks() == [block]
    end

    test "get_block!/1 returns the block with given id" do
      block = block_fixture()
      assert Chain.get_block!(block.id) == block
    end

    test "get_block!/1 returns the block with given height" do
      block = block_fixture()
      assert Chain.get_block!(block.height) == block
    end

    test "get_block!/1 returns the block with given hash" do
      block = block_fixture()
      assert Chain.get_block!(block.hash) == block
    end

    test "create_block/1 with valid data creates a block" do
      valid_attrs = %{
        size: 42,
        timestamp: ~N[2023-10-27 00:02:00],
        version: 1,
        time: 42,
        bits: "some bits",
        hash: "unique_hash_123",
        num_tx: 42,
        chainwork: "some chainwork",
        difficulty: "120.5",
        height: 1000,
        mediantime: 42,
        merkleroot: "some merkleroot",
        nextblockhash: "some nextblockhash",
        prevblockhash: "some prevblockhash",
        nonce: 42,
        tx: []
      }

      assert {:ok, %Block{} = block} = Chain.create_block(valid_attrs)
      assert block.size == 42
      assert block.hash == "unique_hash_123"
      assert block.height == 1000
    end

    test "create_block/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Chain.create_block(@invalid_attrs)
    end

    test "delete_block/1 deletes the block" do
      block = block_fixture()
      assert {:ok, %Block{}} = Chain.delete_block(block)
      assert_raise Ecto.NoResultsError, fn -> Chain.get_block!(block.id) end
    end

    test "change_block/1 returns a block changeset" do
      block = block_fixture()
      assert %Ecto.Changeset{} = Chain.change_block(block)
    end
  end

  describe "transactions" do
    alias Bitblocks.Chain.Transaction

    import Bitblocks.ChainFixtures

    @invalid_attrs %{
      raw: nil,
      txid: nil,
      block_hash: nil
    }

    test "list_transactions/0 returns all transactions" do
      transaction = transaction_fixture()
      assert Chain.list_transactions() == [transaction]
    end

    test "get_transaction!/1 returns the transaction with given id" do
      transaction = transaction_fixture()
      assert Chain.get_transaction!(transaction.id) == transaction
    end

    test "get_transaction!/1 returns the transaction with given txid" do
      transaction = transaction_fixture()
      assert Chain.get_transaction!(transaction.txid) == transaction
    end

    test "create_transaction/1 with valid data creates a transaction" do
      valid_attrs = %{
        raw: "some raw",
        version: "1",
        inputs: [],
        txid: "unique_txid_123",
        block_hash: "some block_hash",
        block_height: 100,
        outputs: [],
        total_input_satoshis: 100_000_000,
        total_output_satoshis: 99_900_000
      }

      assert {:ok, %Transaction{} = transaction} = Chain.create_transaction(valid_attrs)
      assert transaction.raw == "some raw"
      assert transaction.txid == "unique_txid_123"
      assert transaction.block_hash == "some block_hash"
    end

    test "create_transaction/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Chain.create_transaction(@invalid_attrs)
    end

    test "delete_transaction/1 deletes the transaction" do
      transaction = transaction_fixture()
      assert {:ok, %Transaction{}} = Chain.delete_transaction(transaction)
      assert_raise Ecto.NoResultsError, fn -> Chain.get_transaction!(transaction.id) end
    end

    test "change_transaction/1 returns a transaction changeset" do
      transaction = transaction_fixture()
      assert %Ecto.Changeset{} = Chain.change_transaction(transaction)
    end

    test "miner_fee/1 calculates the fee correctly" do
      transaction = transaction_fixture(%{
        total_input_satoshis: 100_000_000,
        total_output_satoshis: 99_900_000
      })

      assert Transaction.miner_fee(transaction) == 100_000
    end

    test "miner_fee/1 returns nil when inputs are nil" do
      transaction = transaction_fixture(%{
        total_input_satoshis: nil,
        total_output_satoshis: 99_900_000
      })

      assert Transaction.miner_fee(transaction) == nil
    end

    test "miner_fee/1 returns nil when outputs are nil" do
      transaction = transaction_fixture(%{
        total_input_satoshis: 100_000_000,
        total_output_satoshis: nil
      })

      assert Transaction.miner_fee(transaction) == nil
    end
  end
end
