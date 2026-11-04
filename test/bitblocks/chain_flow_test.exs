defmodule Bitblocks.ChainFlowTest do
  use Bitblocks.DataCase, async: true

  import Bitblocks.FirstSpendFixtures

  alias Bitblocks.ChainFlow

  setup do
    insert_first_spend()
    :ok
  end

  test "the first spend: block 170 spends block 9's coinbase" do
    {:ok, flow} = ChainFlow.range(0, 200)

    assert Enum.map(flow.txs, &Enum.take(&1, 3)) == [
             [9, coinbase_9(), 1],
             [170, coinbase_170(), 1],
             [170, first_spend(), 0]
           ]

    # One edge, from tx 0 output 0 to tx 2, carrying the 50 coins it spends.
    assert flow.edges == [[0, 0, 2, 5_000_000_000]]
    assert flow.external == []

    # Block 9's coinbase output was spent at 170; the spend's two outputs
    # (10 to Hal, 40 back) are unspent as far as we hold.
    assert Enum.at(flow.outputs, 0) == [[5_000_000_000, 170]]
    assert Enum.at(flow.outputs, 2) == [[1_000_000_000, -1], [4_000_000_000, -1]]
  end

  test "an input from outside the range is an external node at its height" do
    {:ok, flow} = ChainFlow.range(100, 200)
    assert flow.external == [[coinbase_9(), 9]]
    assert flow.edges == [[-1, 0, 1, 5_000_000_000]]
  end

  test "blocks carry their stored tx count beside the header's" do
    {:ok, flow} = ChainFlow.range(0, 200)
    assert flow.blocks == [[9, 1_231_473_279, 1, 1], [170, 1_231_731_025, 2, 2]]
  end

  test "over the tx cap the range is cut at a whole block, and says so" do
    {:ok, flow} = ChainFlow.range(0, 200, max_txs: 2)
    assert flow.truncated
    assert flow.to == 169
    assert length(flow.txs) == 1
  end

  test "rejects a backwards range" do
    assert ChainFlow.range(10, 5) == {:error, :invalid_range}
  end
end
