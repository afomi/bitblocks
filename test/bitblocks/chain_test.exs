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

    test "list_transactions_paginated/0 returns transactions" do
      transaction = transaction_fixture()
      {transactions, _cursor} = Chain.list_transactions_paginated()
      assert Enum.any?(transactions, fn t -> t.txid == transaction.txid end)
    end

    test "confirmations/1 follows the block stored at the tx's height (#34)" do
      block_fixture(%{hash: "done", height: 10, sync_state: "completed"})
      block_fixture(%{hash: "headers", height: 11, sync_state: "header_only"})
      block_fixture(%{hash: "listed", height: 12, sync_state: "txs_syncing"})

      done = transaction_fixture(%{block_hash: "done", block_height: 10})
      headers = transaction_fixture(%{block_hash: "headers", block_height: 11})
      listed = transaction_fixture(%{block_hash: "listed", block_height: 12})
      orphan = transaction_fixture(%{block_hash: "gone", block_height: 13})
      moved = transaction_fixture(%{block_hash: "done", block_height: 9})

      statuses = Chain.confirmations([done, headers, listed, orphan, moved])

      assert statuses[done.txid] == %{confirmed: true, confirmation: "confirmed"}
      assert statuses[headers.txid] == %{confirmed: false, confirmation: "unverified"}
      assert statuses[listed.txid] == %{confirmed: true, confirmation: "confirmed"}
      assert statuses[orphan.txid] == %{confirmed: false, confirmation: "orphaned"}
      assert statuses[moved.txid] == %{confirmed: false, confirmation: "orphaned"}
    end

    test "record_spends/1 replaces a spend from an orphaned block, and only that (#34)" do
      outpoint = Jason.encode!(%{txid: "prev", vout: 0})
      other = Jason.encode!(%{txid: "prev", vout: 1})

      block_fixture(%{hash: "canon", height: 20})

      orphan_spender =
        transaction_fixture(%{txid: "t_orphan", block_hash: "gone", inputs: [outpoint]})

      live_spender =
        transaction_fixture(%{txid: "t_live", block_hash: "canon", inputs: [other]})

      Chain.record_spends(orphan_spender)
      Chain.record_spends(live_spender)

      canonical =
        transaction_fixture(%{
          txid: "t_canon",
          block_hash: "canon",
          inputs: ["{}", outpoint, other]
        })

      Chain.record_spends(canonical)

      assert %{spending_txid: "t_canon", spending_vin: 1} =
               Repo.get_by!(Bitblocks.Chain.Spend, txid: "prev", vout: 0)

      assert %{spending_txid: "t_live", spending_vin: 0} =
               Repo.get_by!(Bitblocks.Chain.Spend, txid: "prev", vout: 1)

      # Re-running either tx is a no-op.
      Chain.record_spends(canonical)

      assert %{spending_txid: "t_canon"} =
               Repo.get_by!(Bitblocks.Chain.Spend, txid: "prev", vout: 0)
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
      transaction =
        transaction_fixture(%{
          total_input_satoshis: 100_000_000,
          total_output_satoshis: 99_900_000
        })

      assert Transaction.miner_fee(transaction) == 100_000
    end

    test "miner_fee/1 returns nil when inputs are nil" do
      transaction =
        transaction_fixture(%{
          total_input_satoshis: nil,
          total_output_satoshis: 99_900_000
        })

      assert Transaction.miner_fee(transaction) == nil
    end

    test "miner_fee/1 returns nil when outputs are nil" do
      transaction =
        transaction_fixture(%{
          total_input_satoshis: 100_000_000,
          total_output_satoshis: nil
        })

      assert Transaction.miner_fee(transaction) == nil
    end
  end
end
