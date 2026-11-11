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

  test "each tx on the block page says what it is and what it moved", %{conn: conn} do
    block_fixture(%{
      height: 155_026,
      hash: "blk155026",
      tx: [],
      num_tx: 2,
      sync_state: "completed"
    })

    transaction_fixture(%{
      txid: "t_coinbase",
      block_hash: "blk155026",
      block_height: 155_026,
      coinbase: true,
      tx_types: ["p2pkh"],
      total_output_satoshis: 2_500_000_000
    })

    transaction_fixture(%{
      txid: "t_data",
      block_hash: "blk155026",
      block_height: 155_026,
      tx_types: ["p2pkh", "op-return", "custom"],
      total_output_satoshis: 18_711_006
    })

    {:ok, view, _html} = live(conn, "/blocks/155026")

    assert has_element?(view, "#block-tx-t_coinbase", "Coinbase")
    assert has_element?(view, "#block-tx-t_coinbase", "25 BSV")
    assert has_element?(view, ~s(#block-tx-t_data [data-type="op-return"]), "OP_RETURN")
    assert has_element?(view, "#block-tx-t_data", "0.18711006 BSV")
    refute has_element?(view, ~s(#block-tx-t_data [data-type="custom"]))
    refute has_element?(view, "#block-tx-t_data", "Coinbase")
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

  describe "sync status" do
    test "a failed block says failed, and no step claims it", %{conn: conn} do
      block = block_fixture(%{sync_state: "failed"})

      {:ok, view, html} = live(conn, ~p"/blocks/#{block.height}")

      assert view |> element("#block-sync-failed") |> render() =~ "Failed."
      refute has_element?(view, "#block-sync-steps")
      refute html =~ "header only"
      assert html =~ "failed to sync"
    end

    test "a block with no step lights none", %{conn: conn} do
      block = block_fixture(%{sync_state: "pending"})

      {:ok, view, _html} = live(conn, ~p"/blocks/#{block.height}")

      refute has_element?(view, "#block-sync-steps .bg-brand-strong")
    end

    test "a completed block says so in one line, with no pipeline", %{conn: conn} do
      block = block_fixture(%{sync_state: "completed", num_tx: 158})

      {:ok, view, _html} = live(conn, ~p"/blocks/#{block.height}")

      assert view |> element("#block-sync-complete") |> render() =~
               "All 158 transactions are stored, and their txids rebuild the merkle root."

      refute has_element?(view, "#block-sync-steps")
    end

    test "a block mid-sync lights its step", %{conn: conn} do
      block = block_fixture(%{sync_state: "header_synced"})

      {:ok, view, _html} = live(conn, ~p"/blocks/#{block.height}")

      assert has_element?(view, "#block-sync-steps .bg-brand-strong")
      assert has_element?(view, "#block-sync-steps .bg-green-500")
    end
  end
end
