defmodule Bitblocks.Chain.CoinbaseFlagsTest do
  # Blocks 401,094..439,213 completed with their coinbase stored unflagged:
  # the tolerant parser didn't read the null outpoint (2026-11-28). The
  # repair flags that one row, so the tally backfill can write the totals.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{CoinbaseFlags, Transaction, TxPipeline}
  alias Bitblocks.Chain.TxPipeline.Backfill

  # Block 403,534's coinbase (1Hash), the block's only tx.
  @txid "e50ad50391a0041e4e95b23ac9a096df99ed1bdcb3137858a8df17fa5cfda7b2"
  @raw "01000000010000000000000000000000000000000000000000000000000000000000000000" <>
         "ffffffff04034e2806ffffffff0200f90295000000001976a91499c02ebccad91945bcb4" <>
         "69e5a66240b3c7ee614e88ac0000000000000000256a28124d696e656420627920316861" <>
         "73682e636f6d468b298a735f6eac735f6eacbc1f00c400000000"

  setup do
    block = block_fixture(%{height: 403_534, num_tx: 1, sync_state: "completed"})

    # As prod holds it: analysed at the current version, flagged false.
    transaction_fixture(%{
      txid: @txid,
      raw: @raw,
      block_hash: block.hash,
      block_height: block.height,
      input_txids: [],
      coinbase: false,
      script_analysis_version: TxPipeline.version(:script_analysis),
      total_input_satoshis: 0,
      total_output_satoshis: 2_500_000_000,
      fee_satoshis: 0,
      burned_satoshis: 0,
      tallies_version: TxPipeline.version(:tallies)
    })

    %{block: block}
  end

  test "a dry run names the block and writes nothing", %{block: block} do
    assert %{examined: 1, unflagged: 1, flagged: 1, flagged_heights: [403_534], applied: false} =
             CoinbaseFlags.run(block.height, block.height)

    assert Repo.get_by!(Transaction, txid: @txid).coinbase == false
  end

  test "apply flags the row, the tally backfill writes the totals, and a rerun finds nothing",
       %{block: block} do
    # Before: the tally backfill can't check the block.
    assert %{details: %{reward_unknown: 1}} = Backfill.run(block.height, block.height)

    assert %{flagged: 1, unwritten: []} =
             CoinbaseFlags.run(block.height, block.height, apply: true)

    assert Repo.get_by!(Transaction, txid: @txid).coinbase == true

    Backfill.run(block.height, block.height, apply: true)
    done = Repo.reload!(block)
    assert done.miner_reward == 2_500_000_000
    assert done.fees_verified == true
    assert done.tallies_version == TxPipeline.version(:block_totals)

    assert %{unflagged: 0, flagged: 0} = CoinbaseFlags.run(block.height, block.height)

    # The acceptance dry run: nothing below the version.
    assert %{rows_below_version: 0, details: %{blocks_below_version: 0, reward_unknown: 0}} =
             Backfill.run(block.height, block.height)
  end

  test "a block whose coinbase row isn't stored is reported, not guessed" do
    other = block_fixture(%{height: 403_535, num_tx: 2, sync_state: "completed"})

    transaction_fixture(%{
      block_hash: other.hash,
      block_height: other.height,
      input_txids: ["aa" |> String.duplicate(32)],
      coinbase: false
    })

    assert %{not_stored: [403_535], flagged: 0} =
             CoinbaseFlags.run(other.height, other.height, apply: true)
  end

  test "genesis and the BIP30 blocks are skipped" do
    block_fixture(%{height: 0, sync_state: "completed"})
    block_fixture(%{height: 91_722, sync_state: "completed"})

    assert %{examined: 2, unflagged: 0} = CoinbaseFlags.run(0, 91_722)
  end
end
