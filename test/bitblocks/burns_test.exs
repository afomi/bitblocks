defmodule Bitblocks.BurnsTest do
  @moduledoc """
  `Bitblocks.Burns`: the blocks that burned sats, by size or height, and the
  stored txs of one block that burned them.
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Burns

  test "lists only blocks that burned, most first or newest first" do
    block_fixture(%{height: 10, burned: 5, sync_state: "completed"})
    block_fixture(%{height: 11, burned: 50, sync_state: "completed"})
    block_fixture(%{height: 12, burned: 0, sync_state: "completed"})
    block_fixture(%{height: 13, burned: 20, sync_state: "completed"})

    assert Enum.map(Burns.blocks(), & &1.height) == [11, 13, 10]
    assert Enum.map(Burns.blocks(order: :height), & &1.height) == [13, 11, 10]
    assert [%{height: 11}] = Burns.blocks(limit: 1)
    assert Burns.summary() == %{blocks: 3, burned: 75}
  end

  test "a block's txs that burned, most first, with their sum" do
    block = block_fixture(%{height: 30, burned: 150, sync_state: "completed"})
    other = block_fixture(%{height: 31, burned: 9, sync_state: "completed"})
    big = String.duplicate("b", 64)
    small = String.duplicate("a", 64)

    transaction_fixture(%{
      txid: small,
      block_hash: block.hash,
      block_height: 30,
      burned_satoshis: 40
    })

    transaction_fixture(%{
      txid: big,
      block_hash: block.hash,
      block_height: 30,
      burned_satoshis: 100
    })

    transaction_fixture(%{block_hash: block.hash, block_height: 30, burned_satoshis: 0})
    transaction_fixture(%{block_hash: block.hash, block_height: 30, burned_satoshis: nil})
    transaction_fixture(%{block_hash: other.hash, block_height: 31, burned_satoshis: 9})

    assert Burns.txs(block.hash) == [%{txid: big, burned: 100}, %{txid: small, burned: 40}]
    assert Burns.txs(block.hash, 1) == [%{txid: big, burned: 100}]
    assert Burns.tx_summary(block.hash) == %{txs: 2, burned: 140}
  end
end
