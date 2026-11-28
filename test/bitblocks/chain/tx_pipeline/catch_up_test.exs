defmodule Bitblocks.Chain.TxPipeline.CatchUpTest do
  # A row stored by an earlier sync is skipped when its block completes, so
  # it never meets the chunk steps. The catch-up brings it up to version.
  use Bitblocks.DataCase, async: false
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, RawBlock, Spend, Transaction, TxIngest, TxPipeline}
  alias Bitblocks.Chain.TxPipeline.CatchUp
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Workers.CatchUpBlockWorker

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  # The genesis coinbase: one 50 BTC output.
  @genesis_txid "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
  @genesis_raw "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

  defp coinbase_json(_height), do: tx_json({@genesis_txid, @genesis_raw})

  defp stored_before_the_pipeline(txid) do
    Repo.delete_all(from(s in Spend, where: s.spending_txid == ^txid))

    Repo.update_all(from(t in Transaction, where: t.txid == ^txid),
      set: [
        block_height: nil,
        coinbase: nil,
        script_analysis_version: nil,
        tallies_version: nil,
        tx_types: nil,
        tx_types_version: nil,
        total_output_satoshis: nil
      ]
    )
  end

  setup do
    block = block_fixture(%{height: 40, sync_state: "completed"})
    {txid, _} = pair = tx([funding_outpoint()], [p2pkh(address(), 1_000)])
    :ok = TxIngest.store(tx_json(pair), block)
    %{block: block, txid: txid}
  end

  test "a block whose rows are current needs nothing and enqueues nothing", %{block: block} do
    refute CatchUp.needed?(block)
    assert CatchUp.enqueue(block) == :ok
    refute_enqueued(worker: CatchUpBlockWorker)
  end

  test "a block holding an older row enqueues one catch-up", %{block: block, txid: txid} do
    stored_before_the_pipeline(txid)

    assert CatchUp.needed?(block)
    assert CatchUp.enqueue(block) == :ok
    assert_enqueued(worker: CatchUpBlockWorker, args: %{"hash" => block.hash})
  end

  test "the job brings the row up to every version, with no run record", %{
    block: block,
    txid: txid
  } do
    stored_before_the_pipeline(txid)
    runs = Repo.aggregate(Run, :count)

    assert :ok = perform_job(CatchUpBlockWorker, %{"hash" => block.hash})

    tx = Chain.get_transaction!(txid)
    assert tx.block_height == 40
    assert tx.script_analysis_version == TxPipeline.version(:script_analysis)
    assert tx.tallies_version == TxPipeline.version(:tallies)
    assert tx.tx_types_version == TxPipeline.version(:tx_types)
    assert tx.total_output_satoshis == 1_000
    assert [%Spend{}] = Repo.all(from(s in Spend, where: s.spending_txid == ^txid))

    refute CatchUp.needed?(block)
    assert Repo.reload!(block).type_counts == %{"p2pkh" => 1}
    assert Repo.aggregate(Run, :count) == runs
  end

  # Block 405,241: every row current and its coinbase flagged, but the block
  # steps at completion failed (the pool exhaustion of 2026-11-22), so its
  # totals stayed NULL and nothing picked it up again.
  test "a block whose rows are current but whose totals weren't written enqueues one" do
    block = block_fixture(%{height: 41, sync_state: "completed"})
    coinbase = coinbase_json(block.height)
    :ok = TxIngest.store(coinbase, block)
    assert Chain.get_transaction!(coinbase["txid"]).coinbase == true
    assert Repo.reload!(block).tallies_version == nil

    assert CatchUp.needed?(block)
    assert CatchUp.enqueue(block) == :ok
    assert_enqueued(worker: CatchUpBlockWorker, args: %{"hash" => block.hash})

    assert :ok = perform_job(CatchUpBlockWorker, %{"hash" => block.hash})

    done = Repo.reload!(block)
    assert done.tallies_version == TxPipeline.version(:block_totals)
    assert done.miner_reward == 5_000_000_000
    refute CatchUp.needed?(block)
  end

  test "a block no longer completed is left alone", %{block: block} do
    Repo.update_all(from(b in Block, where: b.id == ^block.id), set: [sync_state: "failed"])

    assert {:cancel, :block_not_completed} =
             perform_job(CatchUpBlockWorker, %{"hash" => block.hash})
  end
end
