defmodule Bitblocks.Chain.TxPipelineTest do
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, RawBlock, Spend, Transaction, TxIngest, TxPipeline}
  alias Bitblocks.Chain.TxPipeline.Steps
  alias Bitblocks.Workers.FetchTransactionsWorker
  alias BitblocksWeb.RpcStub

  # Real mainnet transactions. Block 170 holds the first payment between
  # people: f4184fc5… spends block 9's coinbase (50 BTC) as 10 to Hal Finney
  # and 40 back. Its coinbase claims the full 50 BTC subsidy, with no fees.
  @block9_coinbase "0437cd7f8525ceed2324359c2d0ba26006d92d856a9c20fa0241106ee5a597c9"
  @block9_coinbase_hex "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0704ffff001d0134ffffffff0100f2052a0100000043410411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac00000000"
  @block170_hash "00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee"
  @block170_root "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff"
  @block170_header "0100000055bd840a78798ad0da853f68974f3d183e2bd1db6a842c1feecf222a00000000ff104ccb05421ab93e63f8c3ce5c2c2e9dbb37de2764b3a3175c8166562cac7d51b96a49ffff001d283e9e70"
  @block170_coinbase "b1fea52486ce0c62bb442b530a3f0132b826c74e473d1f2c220bfa78111c5082"
  @block170_coinbase_hex "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0704ffff001d0102ffffffff0100f2052a01000000434104d46c4968bde02899d2aa0963367c7a6ce34eec332b32e42e5f3407e052d64ac625da6f0718e7b302140434bd725706957c092db53805b821a85b23a7ac61725bac00000000"
  @hal_payment "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"
  @hal_payment_hex "0100000001c997a5e56e104102fa209c6a852dd90660a20b2d9c352423edce25857fcd3704000000004847304402204e45e16932b8af514961a1d3a1a25fdf3f4f7732e9d624c6c61548ab5fb8cd410220181522ec8eca07de4860a4acdd12909d831cc56cbbac4622082221a8768d1d0901ffffffff0200ca9a3b00000000434104ae1a62fe09c5f51b13905f07f06b99a2f7159b2225f374cd378d71302fa28414e7aab37397f554a7df5f142c21c1b7303b8a0626f1baded5c72a704f7e6cd84cac00286bee0000000043410411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac00000000"

  @fifty_btc 5_000_000_000

  setup do
    RpcStub.setup()
    RpcStub.clear()
    :ok
  end

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  defp store_block9 do
    block9 = block_fixture(%{height: 9, sync_state: "completed"})
    assert :ok = TxIngest.store(tx_json({@block9_coinbase, @block9_coinbase_hex}), block9)
    block9
  end

  defp block170_bytes do
    [@block170_header, "02", @block170_coinbase_hex, @hal_payment_hex]
    |> Enum.join()
    |> Base.decode16!(case: :lower)
  end

  defp block170 do
    block_fixture(%{
      height: 170,
      hash: @block170_hash,
      merkleroot: @block170_root,
      num_tx: 2,
      size: nil,
      tx: [],
      sync_state: "header_only"
    })
  end

  describe "steps/0" do
    test "lists every step in run order, by stage" do
      assert Enum.map(TxPipeline.steps(), &{&1.stage(), &1.name()}) == [
               {:chunk, "script_analysis"},
               {:chunk, "sats_out"},
               {:chunk, "burned"},
               {:chunk, "sats_in"},
               {:chunk, "fee"},
               {:chunk, "classify_outputs"},
               {:tx, "record_spends"},
               {:tx, "index_tokens"},
               {:tx, "index_bitcom"},
               {:tx, "index_bap"},
               {:block, "block_totals"},
               {:block, "type_counts"}
             ]

      for step <- TxPipeline.steps() do
        assert step.description() =~ ~r/\A[A-Z].+\.\z/,
               "#{step.name()} needs a one-line description"
      end
    end
  end

  describe "versions (docs/DERIVED_DATA.md)" do
    test "every step has a positive version, and a stage or derivation sums its steps" do
      for step <- TxPipeline.steps() do
        assert is_integer(step.version()) and step.version() > 0, "#{step.name()} needs a version"
      end

      for stage <- [:chunk, :tx, :block] do
        assert TxPipeline.version(stage) ==
                 TxPipeline.steps(stage) |> Enum.map(& &1.version()) |> Enum.sum()
      end

      assert TxPipeline.version(:tallies) ==
               Enum.sum(
                 for s <- [Steps.SatsOut, Steps.Burned, Steps.SatsIn, Steps.Fee], do: s.version()
               )

      assert TxPipeline.version(:block_totals) == Steps.BlockTotals.version()
      assert TxPipeline.version(:tx_types) == Steps.ClassifyOutputs.version()

      assert TxPipeline.version(:type_counts) ==
               Steps.ClassifyOutputs.version() + Steps.TypeCounts.version()
    end

    test "classification keeps one number: the step's version is the classifier's" do
      assert Steps.ClassifyOutputs.version() == Bitblocks.TxTypes.Classifier.version()
    end

    test "script analysis keeps one number: the step's version is the analyzer's" do
      assert Steps.ScriptAnalysis.version() ==
               Bitblocks.TransactionParser.script_analysis_version()

      assert TxPipeline.version(:script_analysis) == Steps.ScriptAnalysis.version()
    end

    test "ingest stamps each tx's tallies and analysis, and the block step stamps the block" do
      store_block9()
      block = block170()
      RpcStub.stub_rest_block(@block170_hash, {:ok, block170_bytes()})

      assert :ok = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      for txid <- [@hal_payment, @block170_coinbase] do
        tx = Chain.get_transaction!(txid)
        assert tx.tallies_version == TxPipeline.version(:tallies)
        assert tx.script_analysis_version == TxPipeline.version(:script_analysis)
      end

      assert Chain.get_block!(170).tallies_version == TxPipeline.version(:block_totals)
    end
  end

  describe "transaction types (#49)" do
    test "ingest types each tx, and the completed block tallies its types" do
      store_block9()
      block = block170()
      RpcStub.stub_rest_block(@block170_hash, {:ok, block170_bytes()})

      assert :ok = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      # 2009: both txs pay to a bare public key.
      for txid <- [@hal_payment, @block170_coinbase] do
        tx = Chain.get_transaction!(txid)
        assert tx.tx_types == ["p2pk"]
        assert tx.tx_types_version == TxPipeline.version(:tx_types)
      end

      completed = Chain.get_block!(170)
      assert completed.type_counts == %{"p2pk" => 2}
      assert completed.type_counts_version == TxPipeline.version(:type_counts)
    end

    test "a tx that doesn't decode stays untyped, and its block's count is unstamped" do
      block = block_fixture(%{height: 30, sync_state: "completed"})
      {txid, hex} = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
      :ok = TxIngest.store(tx_json({txid, hex}), block)

      typed = Chain.get_transaction!(txid)
      assert typed.tx_types == ["p2pkh"]

      Repo.update_all(Transaction, set: [tx_types: nil, tx_types_version: nil])
      TxPipeline.run_block(block)

      reloaded = Repo.reload!(block)
      assert reloaded.type_counts == %{}
      assert reloaded.type_counts_version == nil

      Repo.update_all(Transaction,
        set: [tx_types: ["p2pkh"], tx_types_version: TxPipeline.version(:tx_types)]
      )

      TxPipeline.run_block(block)
      reloaded = Repo.reload!(block)
      assert reloaded.type_counts == %{"p2pkh" => 1}
      assert reloaded.type_counts_version == TxPipeline.version(:type_counts)
    end

    test "the chunk step leaves a row it can't decode untyped" do
      block = block_fixture(%{height: 31})

      assert [%{raw: "zz"} = attrs] =
               Steps.ClassifyOutputs.run_chunk([%{txid: "x", raw: "zz"}], block)

      refute Map.has_key?(attrs, :tx_types)
      refute Map.has_key?(attrs, :tx_types_version)
    end
  end

  describe "block 170, the first payment" do
    test "tallies sats in from block 9's stored coinbase, and the block's totals verify" do
      store_block9()
      block = block170()
      RpcStub.stub_rest_block(@block170_hash, {:ok, block170_bytes()})

      assert :ok = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      payment = Chain.get_transaction!(@hal_payment)
      assert payment.total_input_satoshis == @fifty_btc
      assert payment.total_output_satoshis == @fifty_btc
      assert payment.fee_satoshis == 0
      assert payment.burned_satoshis == 0

      coinbase = Chain.get_transaction!(@block170_coinbase)
      assert coinbase.coinbase
      assert coinbase.total_input_satoshis == 0
      assert coinbase.total_output_satoshis == @fifty_btc
      assert coinbase.fee_satoshis == 0

      completed = Chain.get_block!(170)
      assert completed.sync_state == "completed"
      assert completed.sats_out == @fifty_btc
      assert completed.fees == 0
      assert completed.miner_reward == @fifty_btc
      assert completed.subsidy == @fifty_btc
      assert completed.burned == 0
      assert completed.fees_verified == true
    end

    test "without block 9 stored, sats in and fees are unknown, never guessed" do
      block = block170()
      RpcStub.stub_rest_block(@block170_hash, {:ok, block170_bytes()})

      assert :ok = FetchTransactionsWorker.perform(%Oban.Job{args: %{"block_hash" => block.hash}})

      payment = Chain.get_transaction!(@hal_payment)
      assert payment.total_input_satoshis == nil
      assert payment.fee_satoshis == nil
      assert payment.total_output_satoshis == @fifty_btc

      completed = Chain.get_block!(170)
      assert completed.sync_state == "completed"
      assert completed.fees == nil
      assert completed.fees_verified == nil
      assert completed.miner_reward == @fifty_btc
      assert completed.sats_out == @fifty_btc
    end
  end

  describe "the chunk steps" do
    test "a tx spending an earlier tx in the same chunk gets its sats in" do
      parent = tx([funding_outpoint()], [p2pkh(address(), 7_000), p2pkh(address(), 3_000)])
      {parent_txid, _} = parent
      child = tx(["#{parent_txid}_1"], [p2pkh(address(), 2_500)])
      {child_txid, _} = child
      block = %Block{hash: "chunk-block", height: 500}

      assert [{^parent_txid, :ok}, {^child_txid, :ok}] =
               TxIngest.store_chunk([tx_json(parent), tx_json(child)], block)

      stored = Chain.get_transaction!(child_txid)
      assert stored.total_input_satoshis == 3_000
      assert stored.total_output_satoshis == 2_500
      assert stored.fee_satoshis == 500

      # The parent's own funding input isn't stored: unknown.
      assert Chain.get_transaction!(parent_txid).total_input_satoshis == nil
    end

    test "sats in reads stored previous outputs in one batched lookup" do
      {parent_txid, _} = parent = tx([funding_outpoint()], [p2pkh(address(), 9_000)])
      assert :ok = TxIngest.store(tx_json(parent), %Block{hash: "b1", height: 1})

      assert Steps.SatsIn.lookup([
               {parent_txid, 0},
               {parent_txid, 5},
               {String.duplicate("e", 64), 0}
             ]) ==
               %{{parent_txid, 0} => 9_000}

      child = tx(["#{parent_txid}_0"], [p2pkh(address(), 8_800)])
      assert :ok = TxIngest.store(tx_json(child), %Block{hash: "b2", height: 2})
      {child_txid, _} = child

      assert %{total_input_satoshis: 9_000, fee_satoshis: 200} =
               Chain.get_transaction!(child_txid)
    end

    test "burned counts sats locked in OP_FALSE OP_RETURN and OP_RETURN outputs" do
      burn = %BSV.TxOut{
        satoshis: 500,
        script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "gone"]}
      }

      bare = %BSV.TxOut{satoshis: 25, script: %BSV.Script{chunks: [:OP_RETURN, "also gone"]}}

      {txid, _} =
        t = tx([funding_outpoint()], [p2pkh(address(), 1_000), burn, bare, data_output()])

      assert :ok = TxIngest.store(tx_json(t), %Block{hash: "burn", height: 3})

      assert %{burned_satoshis: 525, total_output_satoshis: 1_525} = Chain.get_transaction!(txid)
    end

    test "a tx with no data outputs burns nothing" do
      {txid, _} = t = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
      assert :ok = TxIngest.store(tx_json(t), %Block{hash: "noburn", height: 4})
      assert Chain.get_transaction!(txid).burned_satoshis == 0
    end
  end

  describe "the existing tx steps, unchanged" do
    test "record_spends, index_tokens, index_bitcom and index_bap run after the insert" do
      parent = tx([funding_outpoint()], [p2pkh(address(), 5_000)])
      {parent_txid, _} = parent
      {child_txid, _} = child = tx(["#{parent_txid}_0"], [p2pkh(address(), 4_000)])

      TxIngest.store_chunk([tx_json(parent), tx_json(child)], %Block{hash: "s", height: 5})

      assert %Spend{spending_txid: ^child_txid, spending_vin: 0} =
               Chain.get_spending_tx(parent_txid, 0)

      tx = Chain.get_transaction!(child_txid)

      assert TxPipeline.run_tx(tx, %Block{hash: "s", height: 5}) == [
               {"record_spends", :ok},
               {"index_tokens", :ok},
               {"index_bitcom", :ok},
               {"index_bap", :ok}
             ]
    end

    # No silent failures: a tx whose spends, tokens or Bitcom rows didn't get
    # recorded must not stay stored, or the retry (which skips stored txids)
    # would never record them and the block would complete without them.
    test "a tx step that raises rolls the tx back, so the block retries it" do
      defmodule RaisingStep do
        def name, do: "raising"
        def stage, do: :tx
        def run(_tx, _block), do: raise("boom")
      end

      Application.put_env(:bitblocks, :tx_pipeline_extra_tx_steps, [RaisingStep])
      on_exit(fn -> Application.delete_env(:bitblocks, :tx_pipeline_extra_tx_steps) end)

      {txid, _} = parent = tx([funding_outpoint()], [p2pkh(address(), 5_000)])

      assert [{^txid, {:error, {:tx_step_failed, ^txid, "raising"}}}] =
               TxIngest.store_chunk([tx_json(parent)], %Block{hash: "r", height: 7})

      refute Repo.get_by(Transaction, txid: txid)
    end

    test "a body that doesn't hash to its txid is rejected before any step" do
      {_txid, hex} = tx([funding_outpoint()], [p2pkh(address(), 5_000)])
      bad = Map.put(tx_json({String.duplicate("f", 64), hex}), "txid", String.duplicate("f", 64))

      assert [{_, {:error, {:body_txid_mismatch, _}}}] =
               TxIngest.store_chunk([bad], %Block{hash: "x", height: 6})

      assert Repo.aggregate(Transaction, :count) == 0
    end
  end

  describe "block_totals" do
    test "a block with no coinbase known keeps no stamp, so a backfill finds it again" do
      block = block_fixture(%{height: 32, sync_state: "completed"})
      {txid, _} = pair = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
      :ok = TxIngest.store(tx_json(pair), block)

      TxPipeline.run_block(block)
      assert %{miner_reward: nil, tallies_version: nil} = Repo.reload!(block)

      Repo.update_all(from(t in Transaction, where: t.txid == ^txid), set: [coinbase: true])
      TxPipeline.run_block(block)

      assert %{miner_reward: 1_000, tallies_version: stamp} = Repo.reload!(block)
      assert stamp == TxPipeline.version(:block_totals)
    end

    test "subsidy halves every 210,000 blocks" do
      assert Steps.BlockTotals.subsidy(0) == 5_000_000_000
      assert Steps.BlockTotals.subsidy(209_999) == 5_000_000_000
      assert Steps.BlockTotals.subsidy(210_000) == 2_500_000_000
      assert Steps.BlockTotals.subsidy(630_000) == 625_000_000
      assert Steps.BlockTotals.subsidy(840_000) == 312_500_000
      assert Steps.BlockTotals.subsidy(64 * 210_000) == 0
    end

    test "a reward above subsidy + fees fails the check; below it still verifies" do
      over = block_fixture(%{height: 7})
      tally_row(over, coinbase: true, out: @fifty_btc + 1, fee: 0)
      tally_row(over, coinbase: false, out: 100, fee: 0)
      TxPipeline.run_block(over)
      assert %{fees_verified: false, fees: 0, miner_reward: 5_000_000_001} = Repo.reload!(over)

      under = block_fixture(%{height: 8})
      tally_row(under, coinbase: true, out: @fifty_btc - 1_000, fee: 0)
      tally_row(under, coinbase: false, out: 100, fee: 300)
      TxPipeline.run_block(under)
      assert %{fees_verified: true, fees: 300, sats_out: 100} = Repo.reload!(under)
    end
  end

  defp tally_row(block, opts) do
    transaction_fixture(%{
      block_hash: block.hash,
      block_height: block.height,
      coinbase: opts[:coinbase],
      total_input_satoshis: nil,
      total_output_satoshis: opts[:out],
      fee_satoshis: opts[:fee],
      burned_satoshis: 0
    })
  end

  describe "output_status/1" do
    test "each output is spent (and by which tx), unspent, or unspendable" do
      {txid, _} =
        t =
        tx([funding_outpoint()], [p2pkh(address(), 1_000), data_output(), p2pkh(address(), 546)])

      {spender, _} = s = tx(["#{txid}_0"], [p2pkh(address(), 900)])
      completed_chain_fixture(9)
      TxIngest.store_chunk([tx_json(t), tx_json(s)], Repo.get_by!(Block, height: 9))

      assert %{
               utxo?: true,
               indexed_through_height: 9,
               tip_height: 9,
               outputs: [
                 %{vout: 0, satoshis: 1_000, status: :spent, spent_by: ^spender, spent_by_vin: 0},
                 %{vout: 1, satoshis: 0, status: :unspendable, spent_by: nil},
                 %{vout: 2, satoshis: 546, status: :unspent, spent_by: nil}
               ]
             } = Chain.output_status(txid)

      assert %{utxo?: true} = Chain.output_status(spender)
      assert Chain.output_status(String.duplicate("0", 64)) == nil

      # A header above the index: no recorded spend is no longer unspent.
      block_fixture(%{height: 10, sync_state: "header_only"})

      assert %{
               utxo?: false,
               indexed_through_height: 9,
               tip_height: 10,
               outputs: [%{status: :spent}, %{status: :unspendable}, %{status: :unknown}]
             } = Chain.output_status(txid)
    end

    test "a tx whose outputs are all spent is not a UTXO" do
      {txid, _} = t = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
      s = tx(["#{txid}_0"], [p2pkh(address(), 900)])
      completed_chain_fixture(10)
      TxIngest.store_chunk([tx_json(t), tx_json(s)], Repo.get_by!(Block, height: 10))

      assert %{utxo?: false} = Chain.output_status(txid)
    end
  end

  describe "nft_facts/1" do
    test "an inscription is an NFT, and its collection item names the collection" do
      collection_id = Bitblocks.OrdinalCollections.known()["grand-tardinians"]
      {txid, _} = t = tx([funding_outpoint()], [item(collection_id, "Tardinian 7", address())])
      assert :ok = TxIngest.store(tx_json(t), %Block{hash: "n", height: 11})

      Repo.insert!(%Bitblocks.OrdinalCollections.Item{
        collection_id: collection_id,
        origin: "#{txid}_0",
        mint_txid: txid,
        current_outpoint: "#{txid}_0",
        name: "Tardinian 7"
      })

      assert %{
               nft?: true,
               inscriptions: [%{vout: 0, content_type: "image/svg+xml"}],
               run?: false,
               collections: [
                 %{
                   slug: "grand-tardinians",
                   name: "Grand Tardinians",
                   item: "Tardinian 7",
                   role: :origin
                 }
               ]
             } = Chain.nft_facts(txid)
    end

    test "a later tx holding a collection item matches by current outpoint" do
      collection_id = Bitblocks.OrdinalCollections.known()["rexxies"]
      {txid, _} = t = tx([funding_outpoint()], [p2pkh(address(), 1)])
      assert :ok = TxIngest.store(tx_json(t), %Block{hash: "m", height: 12})

      Repo.insert!(%Bitblocks.OrdinalCollections.Item{
        collection_id: collection_id,
        origin: "#{String.duplicate("a", 64)}_3",
        mint_txid: String.duplicate("a", 64),
        current_outpoint: "#{txid}_0",
        name: "Rexxie #1"
      })

      assert %{nft?: false, collections: [%{slug: "rexxies", role: :current}]} =
               Chain.nft_facts(txid)
    end

    test "a Run tx is an NFT (a jig); a plain payment is neither" do
      {run_txid, _} = run = tx([funding_outpoint()], [run_payload(%{}), p2pkh(address(), 1)])
      {plain_txid, _} = plain = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
      TxIngest.store_chunk([tx_json(run), tx_json(plain)], %Block{hash: "r", height: 13})

      assert %{nft?: true, run?: true, inscriptions: []} = Chain.nft_facts(run_txid)
      assert %{nft?: false, run?: false, collections: []} = Chain.nft_facts(plain_txid)
    end

    test "a BSV-20 token inscription is fungible, not an NFT" do
      token = %BSV.TxOut{
        satoshis: 1,
        script: %BSV.Script{
          chunks: [
            :OP_FALSE,
            :OP_IF,
            "ord",
            :OP_1,
            "application/bsv-20",
            :OP_0,
            ~s({"p":"bsv-20","op":"mint","tick":"TEST","amt":"1"}),
            :OP_ENDIF
          ]
        }
      }

      {txid, _} = t = tx([funding_outpoint()], [token])
      assert :ok = TxIngest.store(tx_json(t), %Block{hash: "t", height: 14})
      assert %{nft?: false, inscriptions: []} = Chain.nft_facts(txid)
    end
  end
end
