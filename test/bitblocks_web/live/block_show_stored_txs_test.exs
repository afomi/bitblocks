defmodule BitblocksWeb.BlockShowStoredTxsTest do
  # Block 155,025 on prod: completed, txs stored, no txid list on the row.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  test "the block page lists stored txs when the row has no list", %{conn: conn} do
    block_fixture(%{
      height: 155_025,
      hash: "blk155025",
      tx: [],
      num_tx: 2,
      sync_state: "completed"
    })

    for txid <- ~w(t_a t_b),
        do: transaction_fixture(%{txid: txid, block_hash: "blk155025", block_height: 155_025})

    {:ok, _view, html} = live(conn, "/blocks/155025")

    assert html =~ "t_a"
    assert html =~ "t_b"
  end

  test "/blocks shows the next block's row, and a tx count only when known", %{conn: conn} do
    block_fixture(%{height: 959_001, hash: "blk959001"})
    :persistent_term.erase({Bitblocks.NextBlock, 959_001})

    {:ok, _view, html} = live(conn, "/blocks")

    assert html =~ ~s(id="next-block")
    assert html =~ "959,002"
    # The test node answers nothing, so no count is claimed.
    refute html =~ ~s(id="next-block-txs")
  end
end
