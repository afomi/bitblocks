defmodule Bitblocks.Chain.BlockTxidsTest do
  # Block 155,025 on prod: completed, 45 txs stored, but no txid list on the
  # block row (the raw-block path and big blocks don't keep one), so the
  # block page listed nothing.
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.BlockTxids

  test "with no txid list on the row, pages through the stored txs in block order" do
    block = block_fixture(%{height: 155_025, hash: "blk155025", tx: [], num_tx: 3})

    for txid <- ~w(t_a t_b t_c),
        do: transaction_fixture(%{txid: txid, block_hash: "blk155025", block_height: 155_025})

    assert BlockTxids.page(block, 1, 2) == ["t_a", "t_b"]
    assert BlockTxids.page(block, 2, 2) == ["t_c"]
    assert BlockTxids.count(block) == 3
  end

  test "with a txid list on the row, uses it" do
    block = block_fixture(%{height: 7, hash: "blk7", tx: ~w(x y z), num_tx: 3})
    assert BlockTxids.page(block, 1, 2) == ["x", "y"]
  end
end
