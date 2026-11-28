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

    # Script bytes need not parse as opcodes (data after a contract often
    # doesn't), and BSV.Tx.from_binary raises on them. The txid is the hash of
    # the bytes, so the check must not depend on decoding (Grand Tardinians'
    # collection tx, f099182e…, was rejected this way).
    test "accepts a genuine tx whose script the decoder can't parse" do
      raw =
        <<1::little-32, 1, :binary.copy(<<7>>, 32)::binary, 0::little-32, 0,
          0xFFFFFFFF::little-32, 1, 1::little-64, 3, 0x0B, 1, 2, 0::little-32>>

      txid = raw |> then(&:crypto.hash(:sha256, :crypto.hash(:sha256, &1))) |> reverse_hex()
      hex = Base.encode16(raw, case: :lower)

      assert {:error, _} = Bitblocks.Chain.SafeTx.from_hex(hex)
      assert FetchTransactionsWorker.body_matches_txid?(hex, txid)
      refute FetchTransactionsWorker.body_matches_txid?(hex, String.duplicate("0", 64))
    end

    test "lets a nil body through (handled downstream by changeset/analyze)" do
      assert FetchTransactionsWorker.body_matches_txid?(nil, @genesis_txid)
    end
  end

  defp reverse_hex(bin),
    do:
      bin
      |> :binary.bin_to_list()
      |> Enum.reverse()
      |> :binary.list_to_bin()
      |> Base.encode16(case: :lower)

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

      assert {:snooze, 60} =
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

      assert {:snooze, 60} =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      error = Chain.get_block!(block.height).tx_sync_error
      refute error =~ "merkleroot_verification_failed"
      assert error =~ ":no_stub, :getblock"
    end
  end

  describe "completion requires all txs stored (no silent incompleteness)" do
    test "a block whose txs can't be fetched is marked failed, not completed" do
      # Complete, merkleroot-matching txid list so it passes the gate, then the
      # fetch yields nothing (no node in test). Previously the worker walked to
      # the end of the list and marked the block `completed` with 0 txs stored.
      # Now it must end up `failed`, backing off to retry.
      block =
        block_fixture(%{
          height: 999_003,
          hash: "incomplete_fetch_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "header_synced"
        })

      assert {:snooze, 60} =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      reloaded = Chain.get_block!(block.height)
      assert reloaded.sync_state == "failed"
      assert reloaded.tx_sync_error =~ "unfetched_txs"
    end

    test "a tx stored under a block no longer stored is moved here and counted" do
      # The single tx already exists under a block_hash no stored block has
      # (a reorg's orphan). The diff moves it to this block, so the count of
      # rows under this block's hash sees it, and the block completes without
      # refetching. (A BIP30 duplicate coinbase is the test further down.)
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

  describe "the coinbase flag at completion" do
    # A row stored before its block, or analysed when the analyser missed the
    # flag, is skipped as present: no chunk step runs on it. The block's
    # first tx is its coinbase, so completion flags it and the totals get
    # their miner reward (blocks 401,094..439,213, 2026-11-28).
    test "an already stored first tx without the flag is flagged, and the totals are written" do
      block =
        block_fixture(%{
          height: 999_070,
          hash: "coinbase_unflagged_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "txs_queued"
        })

      transaction_fixture(%{
        txid: @genesis_txid,
        raw: @genesis_raw,
        block_hash: block.hash,
        block_height: block.height,
        coinbase: false,
        total_output_satoshis: 5_000_000_000,
        fee_satoshis: 0,
        burned_satoshis: 0
      })

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert Repo.get_by!(Chain.Transaction, txid: @genesis_txid).coinbase == true

      done = Chain.get_block!(block.height)
      assert done.sync_state == "completed"
      assert done.miner_reward == 5_000_000_000
      assert done.tallies_version
    end

    # A source answering with another block's hash (a node or WhatsOnChain
    # mid-reorg) used to file the row under that hash, where this block's
    # count, totals and coinbase never saw it.
    test "a fetched tx is stored under the block being fetched, whatever its JSON says" do
      block =
        block_fixture(%{
          height: 999_071,
          hash: "fetch_json_elsewhere_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "txs_queued"
        })

      RpcStub.stub_getrawtransaction(@genesis_txid, 1, %{
        "txid" => @genesis_txid,
        "hex" => @genesis_raw,
        "blockhash" => "some_competing_block_hash",
        "height" => block.height,
        "version" => 1,
        "vin" => [%{"coinbase" => "04ffff001d0104", "sequence" => 4_294_967_295}],
        "vout" => []
      })

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert Repo.get_by!(Chain.Transaction, txid: @genesis_txid).block_hash == block.hash
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

  describe "a completed block reopened by Sync.reopen_short_blocks/3" do
    test "refills from the node through the pipeline, and a second pass finds nothing" do
      block =
        block_fixture(%{
          height: 999_006,
          hash: "reopened_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [],
          sync_state: "completed"
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

      assert %{reopened: 1} =
               Bitblocks.Sync.reopen_short_blocks(block.height, block.height, apply: true)

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      refilled = Chain.get_block!(block.height)
      assert refilled.sync_state == "completed"
      assert refilled.tallies_version

      tx = Repo.get_by!(Chain.Transaction, txid: @genesis_txid)
      assert tx.block_hash == block.hash
      assert tx.script_analysis_version

      assert %{short: 0, reopened: 0} =
               Bitblocks.Sync.reopen_short_blocks(block.height, block.height, apply: true)
    end
  end

  describe "progress for /syncing" do
    test "the fetch reports synced and processed counts as it walks the block" do
      block =
        block_fixture(%{
          height: 999_006,
          hash: "progress_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "txs_queued"
        })

      RpcStub.stub_getrawtransaction(@genesis_txid, 1, %{
        "txid" => @genesis_txid,
        "hex" => @genesis_raw,
        "blockhash" => block.hash,
        "height" => block.height,
        "version" => 1,
        "vin" => [%{"coinbase" => "04ffff001d0104", "sequence" => 4_294_967_295}],
        "vout" => []
      })

      Phoenix.PubSub.subscribe(Bitblocks.PubSub, Bitblocks.SyncProgress.Tracker.topic())

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert_receive {:sync_progress, %{hash: "progress_hash", stored: 0, processed: 0, total: 1}}

      assert_receive {:sync_progress,
                      %{
                        hash: "progress_hash",
                        stored: 1,
                        processed: 1,
                        total: 1
                      }}
    end
  end

  describe "projection webhooks (#29 step 4)" do
    # A completion near our tip notifies webhook projections of matches in
    # the block; one deep in history doesn't (history is served by hydrate).
    for {tip_above, expected} <- [{0, 1}, {500, 0}] do
      test "a completion #{tip_above} blocks below our tip enqueues #{expected} delivery" do
        if unquote(tip_above) > 0,
          do: block_fixture(%{height: 999_006 + unquote(tip_above), hash: "webhook_tip"})

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
                 FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

        assert length(all_enqueued(worker: Bitblocks.Workers.ProjectionWebhookWorker)) ==
                 unquote(expected)
      end
    end
  end

  describe "fallback sources (our node down, PublicNode pruned)" do
    test "a pruned block completes from WhatsOnChain" do
      block =
        block_fixture(%{
          height: 999_050,
          hash: "fetch_pruned_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [],
          sync_state: "txs_queued"
        })

      RpcStub.stub_getblock(
        block.hash,
        1,
        {:error, %{"code" => -1, "message" => "Block file x not available."}}
      )

      Process.put(:woc_block_txids, %{block.hash => [@genesis_txid]})

      Process.put(:woc_txs, %{
        @genesis_txid => %{
          "txid" => @genesis_txid,
          "hex" => @genesis_raw,
          "vin" => [],
          "vout" => []
        }
      })

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert Chain.get_block!(block.height).sync_state == "completed"
    end

    test "a rate limit backs off and keeps the block's place" do
      block =
        block_fixture(%{
          height: 999_051,
          hash: "fetch_rate_limited_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "txs_queued"
        })

      Process.put(:woc_txs_error, {:http_status, 429, "slow down"})

      assert {:snooze, 60} =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      reloaded = Chain.get_block!(block.height)
      assert reloaded.tx_sync_error =~ "rate_limited"
      assert reloaded.tx_sync_attempts == 1
    end
  end

  describe "a transaction re-mined after a reorg (#34)" do
    # The tx is already stored under the orphaned block's hash. Diff-and-fill
    # used to skip it as present, so it kept the old block_hash forever.
    test "is moved to the block being fetched" do
      block =
        block_fixture(%{
          height: 999_060,
          hash: "fetch_replacement_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "txs_queued"
        })

      transaction_fixture(%{
        txid: @genesis_txid,
        block_hash: "orphaned_hash_not_stored",
        block_height: 999_060
      })

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      tx = Chain.get_transaction!(@genesis_txid)
      assert tx.block_hash == block.hash
      assert tx.block_height == block.height
      assert Chain.get_block!(block.height).sync_state == "completed"
      # Already stored: never fetched again.
      assert RpcStub.calls(:batch_getrawtransaction) == []
    end

    # A row under another stored block is left alone, and it doesn't count
    # for this one: completion counts rows under the block's own hash, so a
    # block never completes with a tx its totals and coinbase can't see.
    test "is left alone when its block is still stored, and the block doesn't complete" do
      other = block_fixture(%{height: 999_061, hash: "fetch_other_stored_block"})

      block =
        block_fixture(%{
          height: 999_062,
          hash: "fetch_dup_hash",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "txs_queued"
        })

      transaction_fixture(%{
        txid: @genesis_txid,
        block_hash: other.hash,
        block_height: other.height
      })

      assert {:snooze, _} =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert Chain.get_transaction!(@genesis_txid).block_hash == other.hash
      block = Chain.get_block!(block.height)
      assert block.sync_state == "failed"
      assert block.tx_sync_error =~ "incomplete"
    end

    # BIP30: 91,722's coinbase txid is stored under 91,880, which holds it
    # again. The one case allowed to complete without its row.
    test "a BIP30 duplicate coinbase block completes with its row under the later block" do
      later = block_fixture(%{height: 91_880, hash: "fetch_bip30_later"})

      block =
        block_fixture(%{
          height: 91_722,
          hash: "fetch_bip30_earlier",
          merkleroot: @genesis_merkleroot,
          num_tx: 1,
          tx: [@genesis_txid],
          sync_state: "txs_queued"
        })

      transaction_fixture(%{
        txid: @genesis_txid,
        block_hash: later.hash,
        block_height: later.height
      })

      assert :ok =
               FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      assert Chain.get_transaction!(@genesis_txid).block_hash == later.hash
      assert Chain.get_block!(block.height).sync_state == "completed"
    end
  end
end
