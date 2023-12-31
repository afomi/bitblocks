defmodule Bitblocks.ChainTest do
  use Bitblocks.DataCase

  alias Bitblocks.Chain

  describe "blocks" do
    # alias Bitblocks.Chain.Block

    import Bitblocks.ChainFixtures

    @invalid_attrs %{size: nil, timestamp: nil, version: nil, time: nil, bits: nil, hash: nil, num_tx: nil, chainwork: nil, difficulty: nil, height: nil, mediantime: nil, merkleroot: nil, nextblockhash: nil, prevblockhash: nil, nonce: nil}

    test "list_blocks/0 returns all blocks" do
      block = block_fixture()
      assert Chain.list_blocks() == [block]
    end

    test "get_block!/1 returns the block with given id" do
      block = block_fixture()
      assert Chain.get_block!(block.id) == block
    end

    test "create_block/1 with valid data creates a block" do
      valid_attrs = %{size: 42, timestamp: ~N[2023-10-27 00:02:00], version: 42, time: 42, bits: "some bits", hash: "some hash", num_tx: 42, chainwork: "some chainwork", difficulty: 42, height: 42, mediantime: 42, merkleroot: "some merkleroot", nextblockhash: "some nextblockhash", prevblockhash: "some prevblockhash", nonce: 42}

      assert {:ok, %Block{} = block} = Chain.create_block(valid_attrs)
      assert block.size == 42
      assert block.timestamp == ~N[2023-10-27 00:02:00]
      assert block.version == 42
      assert block.time == 42
      assert block.bits == "some bits"
      assert block.hash == "some hash"
      assert block.num_tx == 42
      assert block.chainwork == "some chainwork"
      assert block.difficulty == 42
      assert block.height == 42
      assert block.mediantime == 42
      assert block.merkleroot == "some merkleroot"
      assert block.nextblockhash == "some nextblockhash"
      assert block.prevblockhash == "some prevblockhash"
      assert block.nonce == 42
    end

    test "create_block/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Chain.create_block(@invalid_attrs)
    end

    test "update_block/2 with valid data updates the block" do
      block = block_fixture()
      update_attrs = %{size: 43, timestamp: ~N[2023-10-28 00:02:00], version: 43, time: 43, bits: "some updated bits", hash: "some updated hash", num_tx: 43, chainwork: "some updated chainwork", difficulty: 43, height: 43, mediantime: 43, merkleroot: "some updated merkleroot", nextblockhash: "some updated nextblockhash", prevblockhash: "some updated prevblockhash", nonce: 43}

      assert {:ok, %Block{} = block} = Chain.update_block(block, update_attrs)
      assert block.size == 43
      assert block.timestamp == ~N[2023-10-28 00:02:00]
      assert block.version == 43
      assert block.time == 43
      assert block.bits == "some updated bits"
      assert block.hash == "some updated hash"
      assert block.num_tx == 43
      assert block.chainwork == "some updated chainwork"
      assert block.difficulty == 43
      assert block.height == 43
      assert block.mediantime == 43
      assert block.merkleroot == "some updated merkleroot"
      assert block.nextblockhash == "some updated nextblockhash"
      assert block.prevblockhash == "some updated prevblockhash"
      assert block.nonce == 43
    end

    test "update_block/2 with invalid data returns error changeset" do
      block = block_fixture()
      assert {:error, %Ecto.Changeset{}} = Chain.update_block(block, @invalid_attrs)
      assert block == Chain.get_block!(block.id)
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

  describe "blocks" do
    alias Bitblocks.Block

    import Bitblocks.ChainFixtures

    @invalid_attrs %{size: nil, timestamp: nil, version: nil, time: nil, bits: nil, hash: nil, num_tx: nil, chainwork: nil, difficulty: nil, height: nil, mediantime: nil, merkleroot: nil, nextblockhash: nil, prevblockhash: nil, nonce: nil}

    test "list_blocks/0 returns all blocks" do
      block = block_fixture()
      assert Chain.list_blocks() == [block]
    end

    test "get_block!/1 returns the block with given id" do
      block = block_fixture()
      assert Chain.get_block!(block.id) == block
    end

    test "create_block/1 with valid data creates a block" do
      valid_attrs = %{size: 42, timestamp: ~N[2023-12-22 06:00:00], version: 42, time: 42, bits: "some bits", hash: "some hash", num_tx: 42, chainwork: "some chainwork", difficulty: 42, height: 42, mediantime: 42, merkleroot: "some merkleroot", nextblockhash: "some nextblockhash", prevblockhash: "some prevblockhash", nonce: 42}

      assert {:ok, %Block{} = block} = Chain.create_block(valid_attrs)
      assert block.size == 42
      assert block.timestamp == ~N[2023-12-22 06:00:00]
      assert block.version == 42
      assert block.time == 42
      assert block.bits == "some bits"
      assert block.hash == "some hash"
      assert block.num_tx == 42
      assert block.chainwork == "some chainwork"
      assert block.difficulty == 42
      assert block.height == 42
      assert block.mediantime == 42
      assert block.merkleroot == "some merkleroot"
      assert block.nextblockhash == "some nextblockhash"
      assert block.prevblockhash == "some prevblockhash"
      assert block.nonce == 42
    end

    test "create_block/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Chain.create_block(@invalid_attrs)
    end

    test "update_block/2 with valid data updates the block" do
      block = block_fixture()
      update_attrs = %{size: 43, timestamp: ~N[2023-12-23 06:00:00], version: 43, time: 43, bits: "some updated bits", hash: "some updated hash", num_tx: 43, chainwork: "some updated chainwork", difficulty: 43, height: 43, mediantime: 43, merkleroot: "some updated merkleroot", nextblockhash: "some updated nextblockhash", prevblockhash: "some updated prevblockhash", nonce: 43}

      assert {:ok, %Block{} = block} = Chain.update_block(block, update_attrs)
      assert block.size == 43
      assert block.timestamp == ~N[2023-12-23 06:00:00]
      assert block.version == 43
      assert block.time == 43
      assert block.bits == "some updated bits"
      assert block.hash == "some updated hash"
      assert block.num_tx == 43
      assert block.chainwork == "some updated chainwork"
      assert block.difficulty == 43
      assert block.height == 43
      assert block.mediantime == 43
      assert block.merkleroot == "some updated merkleroot"
      assert block.nextblockhash == "some updated nextblockhash"
      assert block.prevblockhash == "some updated prevblockhash"
      assert block.nonce == 43
    end

    test "update_block/2 with invalid data returns error changeset" do
      block = block_fixture()
      assert {:error, %Ecto.Changeset{}} = Chain.update_block(block, @invalid_attrs)
      assert block == Chain.get_block!(block.id)
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

  describe "blocks" do
    alias Bitblocks.Chain.Block

    import Bitblocks.ChainFixtures

    @invalid_attrs %{size: nil, timestamp: nil, version: nil, time: nil, bits: nil, hash: nil, num_tx: nil, chainwork: nil, difficulty: nil, height: nil, mediantime: nil, merkleroot: nil, nextblockhash: nil, prevblockhash: nil, nonce: nil}

    test "list_blocks/0 returns all blocks" do
      block = block_fixture()
      assert Chain.list_blocks() == [block]
    end

    test "get_block!/1 returns the block with given id" do
      block = block_fixture()
      assert Chain.get_block!(block.id) == block
    end

    test "create_block/1 with valid data creates a block" do
      valid_attrs = %{size: 42, timestamp: ~N[2023-12-30 20:27:00], version: 42, time: 42, bits: "some bits", hash: "some hash", num_tx: 42, chainwork: "some chainwork", difficulty: 42, height: 42, mediantime: 42, merkleroot: "some merkleroot", nextblockhash: "some nextblockhash", prevblockhash: "some prevblockhash", nonce: 42}

      assert {:ok, %Block{} = block} = Chain.create_block(valid_attrs)
      assert block.size == 42
      assert block.timestamp == ~N[2023-12-30 20:27:00]
      assert block.version == 42
      assert block.time == 42
      assert block.bits == "some bits"
      assert block.hash == "some hash"
      assert block.num_tx == 42
      assert block.chainwork == "some chainwork"
      assert block.difficulty == 42
      assert block.height == 42
      assert block.mediantime == 42
      assert block.merkleroot == "some merkleroot"
      assert block.nextblockhash == "some nextblockhash"
      assert block.prevblockhash == "some prevblockhash"
      assert block.nonce == 42
    end

    test "create_block/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Chain.create_block(@invalid_attrs)
    end

    test "update_block/2 with valid data updates the block" do
      block = block_fixture()
      update_attrs = %{size: 43, timestamp: ~N[2023-12-31 20:27:00], version: 43, time: 43, bits: "some updated bits", hash: "some updated hash", num_tx: 43, chainwork: "some updated chainwork", difficulty: 43, height: 43, mediantime: 43, merkleroot: "some updated merkleroot", nextblockhash: "some updated nextblockhash", prevblockhash: "some updated prevblockhash", nonce: 43}

      assert {:ok, %Block{} = block} = Chain.update_block(block, update_attrs)
      assert block.size == 43
      assert block.timestamp == ~N[2023-12-31 20:27:00]
      assert block.version == 43
      assert block.time == 43
      assert block.bits == "some updated bits"
      assert block.hash == "some updated hash"
      assert block.num_tx == 43
      assert block.chainwork == "some updated chainwork"
      assert block.difficulty == 43
      assert block.height == 43
      assert block.mediantime == 43
      assert block.merkleroot == "some updated merkleroot"
      assert block.nextblockhash == "some updated nextblockhash"
      assert block.prevblockhash == "some updated prevblockhash"
      assert block.nonce == 43
    end

    test "update_block/2 with invalid data returns error changeset" do
      block = block_fixture()
      assert {:error, %Ecto.Changeset{}} = Chain.update_block(block, @invalid_attrs)
      assert block == Chain.get_block!(block.id)
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

    @invalid_attrs %{raw: nil, version: nil, inputs: nil, txid: nil, block_hash: nil, outputs: nil}

    test "list_transactions/0 returns all transactions" do
      transaction = transaction_fixture()
      assert Chain.list_transactions() == [transaction]
    end

    test "get_transaction!/1 returns the transaction with given id" do
      transaction = transaction_fixture()
      assert Chain.get_transaction!(transaction.id) == transaction
    end

    test "create_transaction/1 with valid data creates a transaction" do
      valid_attrs = %{raw: "some raw", version: "some version", inputs: [], txid: "some txid", block_hash: "some block_hash", outputs: []}

      assert {:ok, %Transaction{} = transaction} = Chain.create_transaction(valid_attrs)
      assert transaction.raw == "some raw"
      assert transaction.version == "some version"
      assert transaction.inputs == []
      assert transaction.txid == "some txid"
      assert transaction.block_hash == "some block_hash"
      assert transaction.outputs == []
    end

    test "create_transaction/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Chain.create_transaction(@invalid_attrs)
    end

    test "update_transaction/2 with valid data updates the transaction" do
      transaction = transaction_fixture()
      update_attrs = %{raw: "some updated raw", version: "some updated version", inputs: [], txid: "some updated txid", block_hash: "some updated block_hash", outputs: []}

      assert {:ok, %Transaction{} = transaction} = Chain.update_transaction(transaction, update_attrs)
      assert transaction.raw == "some updated raw"
      assert transaction.version == "some updated version"
      assert transaction.inputs == []
      assert transaction.txid == "some updated txid"
      assert transaction.block_hash == "some updated block_hash"
      assert transaction.outputs == []
    end

    test "update_transaction/2 with invalid data returns error changeset" do
      transaction = transaction_fixture()
      assert {:error, %Ecto.Changeset{}} = Chain.update_transaction(transaction, @invalid_attrs)
      assert transaction == Chain.get_transaction!(transaction.id)
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
  end
end
