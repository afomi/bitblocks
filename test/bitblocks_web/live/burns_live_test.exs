defmodule BitblocksWeb.BurnsLiveTest do
  @moduledoc """
  The /burns page: admin-gated, lists the blocks that burned, and opens a
  block to the stored txs that burned, each linked to its tx page.
  """
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  describe "access" do
    setup do
      previous = Application.get_env(:bitblocks, :admin_auth)
      Application.put_env(:bitblocks, :admin_auth, enabled: true)
      on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, previous) end)
      :ok
    end

    test "an anonymous visitor is refused", %{conn: conn} do
      conn = get(conn, "/burns")
      refute conn.status == 200
      assert conn.halted
    end
  end

  test "lists burning blocks and opens one to its txs", %{conn: conn} do
    block = block_fixture(%{height: 20, burned: 150_000_000, sync_state: "completed"})
    block_fixture(%{height: 21, burned: 0, sync_state: "completed"})
    txid = String.duplicate("c", 64)

    transaction_fixture(%{
      txid: txid,
      block_hash: block.hash,
      block_height: 20,
      burned_satoshis: 100_000_000
    })

    {:ok, view, html} = live(conn, "/burns")

    assert html =~ "1 blocks burned 1.5 BSV in all."
    assert has_element?(view, "#burn-block-20")
    refute has_element?(view, "#burn-block-21")
    refute has_element?(view, "#burn-txs")

    view |> element("#burn-open-20") |> render_click()

    assert_patch(view, "/burns?" <> URI.encode_query(block: block.hash))
    assert has_element?(view, ~s(#burn-txs a[href="/transactions/#{txid}"]))
    assert render(view) =~ "1 stored txs burned 1 BSV of the block&#39;s 1.5 BSV."
    assert render(view) =~ "not stored yet"

    view |> element("#burns-order-height") |> render_click()
    assert_patch(view, "/burns?" <> URI.encode_query(order: "height", block: block.hash))
  end
end
