defmodule Bitblocks.Chain.TxPipeline.CatchUpTest do
  # A row stored by an earlier sync is skipped when its block completes, so
  # it never meets the chunk steps. The catch-up brings it up to version.
  use Bitblocks.DataCase, async: false
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, RawBlock, Transaction, TxIngest, TxPipeline}
  alias Bitblocks.Chain.TxPipeline.CatchUp
  alias Bitblocks.Derivations.Run
  alias Bitblocks.Workers.CatchUpBlockWorker

  defp tx_json({txid, hex}), do: RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed))

  defp stored_before_the_pipeline(txid) do
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

    refute CatchUp.needed?(block)
    assert Repo.reload!(block).type_counts == %{"p2pkh" => 1}
    assert Repo.aggregate(Run, :count) == runs
  end

  test "a block no longer completed is left alone", %{block: block} do
    Repo.update_all(from(b in Block, where: b.id == ^block.id), set: [sync_state: "failed"])

    assert {:cancel, :block_not_completed} =
             perform_job(CatchUpBlockWorker, %{"hash" => block.hash})
  end
end
