defmodule Bitblocks.Workers.FetchTransactionsWorkerTest do
  use Bitblocks.DataCase
  use Oban.Testing, repo: Bitblocks.Repo

  alias Bitblocks.Chain
  alias Bitblocks.Workers.FetchTransactionsWorker

  import Bitblocks.ChainFixtures

  alias BitblocksWeb.RpcStub

  setup do
    RpcStub.setup()
    RpcStub.clear()
    :ok
  end

  # Real genesis block: single tx whose id equals the merkleroot.
  @genesis_merkleroot "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
  @genesis_txid "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"

  # The genesis coinbase raw tx — hashes to @genesis_txid.
  @genesis_raw "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

  describe "tx body-hash verification (threat T4)" do
    test "accepts a body that hashes to its claimed txid" do
      assert FetchTransactionsWorker.body_matches_txid?(@genesis_raw, @genesis_txid)
    end

    test "rejects a body that does not hash to the claimed txid (doctored body)" do
      refute FetchTransactionsWorker.body_matches_txid?(@genesis_raw, String.duplicate("00", 32))
    end

    test "rejects an undecodable/garbage body (fail closed)" do
      refute FetchTransactionsWorker.body_matches_txid?("not-valid-hex", @genesis_txid)
      refute FetchTransactionsWorker.body_matches_txid?("deadbeef", @genesis_txid)
    end

    test "lets a nil body through (handled downstream by changeset/analyze)" do
      assert FetchTransactionsWorker.body_matches_txid?(nil, @genesis_txid)
    end
  end

  describe "merkleroot gate (threat T4)" do
    test "a block whose txid list doesn't match its merkleroot is rejected and marked failed" do
      block =
        block_fixture(%{
          height: 999_001,
          hash: "merkle_bad_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          # Complete list (length == num_tx) but a poisoned txid → must not match.
          tx: [String.duplicate("ab", 32)],
          sync_state: "header_synced"
        })

      assert {:error, {:merkleroot_verification_failed, _}} =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      # Block was failed, not advanced toward completion — and no tx was fetched.
      reloaded = Chain.get_block!(block.height)
      assert reloaded.sync_state == "failed"
      assert reloaded.tx_sync_error =~ "merkleroot_verification_failed"
    end

    test "an incomplete txid list triggers a re-fetch of the full list, not a skipped check" do
      # num_tx says 5 but only 1 stored → the stored array is incomplete, so
      # TxidSource re-fetches the txid list from the node instead of trusting
      # (or skipping verification of) the partial array. With no stub for
      # getblock the re-fetch fails — the error must be the fetch, never a
      # merkleroot rejection of the partial list, and never a trivial pass.
      block =
        block_fixture(%{
          height: 999_002,
          hash: "merkle_incomplete_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 5,
          tx: [@genesis_txid],
          sync_state: "header_synced"
        })

      result = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      refute match?({:error, {:merkleroot_verification_failed, _}}, result)
      assert {:error, {:no_stub, :getblock, _}} = result
    end
  end

  describe "completion requires all txs stored (no silent incompleteness)" do
    test "a block whose txs can't be fetched is marked failed, not completed" do
      # Complete, merkleroot-matching txid list so it passes the gate, then the
      # fetch yields nothing (no node in test). Previously the worker walked to
      # the end of the list and marked the block `completed` with 0 txs stored.
      # Now it must end up `failed` with an :incomplete error so Oban retries.
      block =
        block_fixture(%{
          height: 999_003,
          hash: "incomplete_fetch_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "header_synced"
        })

      assert {:error, {:incomplete, 0, 1}} =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      reloaded = Chain.get_block!(block.height)
      assert reloaded.sync_state == "failed"
      assert reloaded.tx_sync_error =~ "incomplete"
    end

    test "completeness counts the block's txids anywhere in the table, not by block_hash" do
      # The single tx already exists, but stored under a DIFFERENT block_hash
      # (as happens with a reorg or a BIP30 duplicate coinbase). A block_hash
      # count would see 0 and wedge the block in failed forever; the intersection
      # count sees the txid is present, so the block completes without refetching.
      transaction_fixture(%{txid: @genesis_txid, block_hash: "some_other_block"})

      block =
        block_fixture(%{
          height: 999_004,
          hash: "intersection_complete_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "header_synced"
        })

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert Chain.get_block!(block.height).sync_state == "completed"
    end
  end

  describe "empty stored tx array (the >10k truncation hole)" do
    test "a block with tx: [] and num_tx > 0 re-fetches its list and completes with rows stored" do
      # Previously total = length(block.tx) = 0, so the completeness gate passed
      # trivially (0 >= 0) and the block was marked `completed` with ZERO
      # transactions stored — the silent-incompleteness bug for >10k-tx blocks.
      # Now the txid list is re-fetched, merkleroot-verified, and the block only
      # completes once every transaction is actually stored.
      block =
        block_fixture(%{
          height: 999_005,
          hash: "empty_array_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [],
          sync_state: "header_synced"
        })

      RpcStub.stub_getblock(block.hash, 1, %{"hash" => block.hash, "tx" => [@genesis_txid]})

      RpcStub.stub_getrawtransaction(@genesis_txid, 1, %{
        "txid" => @genesis_txid,
        "hex" => @genesis_raw,
        "blockhash" => block.hash,
        "height" => block.height,
        "version" => 1,
        "vin" => [%{"coinbase" => "04ffff001d0104", "sequence" => 4_294_967_295}],
        "vout" => []
      })

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert Chain.get_block!(block.height).sync_state == "completed"
      assert %Chain.Transaction{} = Repo.get_by(Chain.Transaction, txid: @genesis_txid)
    end
  end

  describe "projection webhooks (#29 step 4)" do
    # A tip-lane completion notifies webhook projections of matches in the
    # block; a backfill completion doesn't (history is served by hydrate).
    for {queue, expected} <- [{"transactions_tip", 1}, {"transactions_backfill", 0}] do
      test "#{queue} completion enqueues #{expected} delivery" do
        block =
          block_fixture(%{
            height: 999_006,
            hash: "webhook_block_hash",
            merkleroot: @genesis_merkleroot,
            num_tx: 1,
            tx: [],
            sync_state: "header_synced"
          })

        {:ok, _} =
          Bitblocks.Projections.create(%{
            tenant: "t",
            name: "n",
            filter: %{"output_addresses" => ["1Donation"]},
            webhook_url: "https://example.test/hook"
          })

        # Already stored under this block, so it matches once the block completes.
        transaction_fixture(%{
          block_height: block.height,
          block_hash: block.hash,
          output_addresses: ["1Donation"]
        })

        RpcStub.stub_getblock(block.hash, 1, %{"hash" => block.hash, "tx" => [@genesis_txid]})

        RpcStub.stub_getrawtransaction(@genesis_txid, 1, %{
          "txid" => @genesis_txid,
          "hex" => @genesis_raw,
          "blockhash" => block.hash,
          "height" => block.height,
          "version" => 1,
          "vin" => [%{"coinbase" => "04ffff001d0104", "sequence" => 4_294_967_295}],
          "vout" => []
        })

        assert :ok =
                 FetchTransactionsWorker.perform(%Oban.Job{
                   args: %{"block_hash" => block.hash},
                   queue: unquote(queue)
                 })

        assert length(all_enqueued(worker: Bitblocks.Workers.ProjectionWebhookWorker)) ==
                 unquote(expected)
      end
    end
  end
end
