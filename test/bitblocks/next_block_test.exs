defmodule Bitblocks.NextBlockTest do
  # The row above /blocks: the next block after our newest header, and what
  # is known about it. Never a guess: a count only when the node gives one.
  use ExUnit.Case, async: true

  alias Bitblocks.NextBlock

  test "on chain and verified by our node: its tx count from the node's header" do
    info =
      NextBlock.info(959_001, %{
        node: %{"blocks" => 960_000, "headers" => 973_992},
        header: fn 959_002 -> {:ok, %{"num_tx" => 1_234}} end,
        mempool: fn -> flunk("not at the tip") end
      })

    assert info == %{height: 959_002, state: :on_chain, num_tx: 1_234}
  end

  test "on chain but our node is still verifying it: no count, and how far the node has got" do
    info =
      NextBlock.info(959_001, %{
        node: %{"blocks" => 957_678, "headers" => 973_992},
        header: fn _ -> flunk("the node can't name it yet") end,
        mempool: fn -> flunk("not at the tip") end
      })

    assert info == %{
             height: 959_002,
             state: :node_verifying,
             num_tx: nil,
             node_blocks: 957_678,
             node_headers: 973_992
           }
  end

  test "at the network tip: assembling, with the mempool's tx count" do
    info =
      NextBlock.info(973_992, %{
        node: %{"blocks" => 973_992, "headers" => 973_992},
        header: fn _ -> flunk("not mined yet") end,
        mempool: fn -> {:ok, %{"size" => 312}} end
      })

    assert info == %{height: 973_993, state: :assembling, num_tx: 312}
  end

  test "node unreachable: just the height" do
    info = NextBlock.info(10, %{node: {:error, :econnrefused}, header: nil, mempool: nil})
    assert info == %{height: 11, state: :unknown, num_tx: nil}
  end
end
