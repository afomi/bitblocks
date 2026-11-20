defmodule BitblocksWeb.BlockShowBoundedTest do
  # A block page for a large block far above the sync ran for minutes and
  # returned 500. The block row renders at once; the transactions panel
  # loads after connect under a statement timeout, and a slow read says so.
  #
  # Not async: the slow-read test locks `transactions` from a second
  # connection.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  defp far_tip_block(height) do
    block_fixture(%{
      height: height,
      hash: "far#{height}",
      sync_state: "header_only",
      num_tx: 4_000_000,
      tx: []
    })
  end

  test "a far-tip block with millions of txs renders, then says its txids aren't synced",
       %{conn: conn} do
    far_tip_block(957_599)

    # The first paint is the block row alone: no transactions query at all.
    html = conn |> get("/blocks/957599") |> html_response(200)
    assert html =~ "957599"
    assert html =~ ~s(id="block-txs-loading")

    {:ok, view, _html} = live(conn, "/blocks/957599")
    html = render_async(view)

    assert html =~ "Transaction IDs not yet synced for this block."
    refute has_element?(view, "#block-txs-loading")
    refute has_element?(view, "#block-txs-unavailable")
  end

  test "a slow read gives the block and an honest note, then loads on another try",
       %{conn: conn} do
    far_tip_block(957_600)
    previous = Application.get_env(:bitblocks, :block_page_read_timeout_ms)
    Application.put_env(:bitblocks, :block_page_read_timeout_ms, 200)

    {:ok, locker} =
      Bitblocks.Repo.config()
      |> Keyword.drop([:pool, :pool_size, :ownership_timeout])
      |> Postgrex.start_link()

    test_pid = self()

    holder =
      spawn_link(fn ->
        Postgrex.transaction(locker, fn conn ->
          Postgrex.query!(conn, "SET LOCAL lock_timeout = 5000", [])
          Postgrex.query!(conn, "LOCK TABLE transactions IN ACCESS EXCLUSIVE MODE", [])
          send(test_pid, :locked)

          receive do
            :release -> :ok
          end
        end)

        send(test_pid, :released)
      end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bitblocks, :block_page_read_timeout_ms, previous),
        else: Application.delete_env(:bitblocks, :block_page_read_timeout_ms)
    end)

    assert_receive :locked, 5_000

    {micros, {view, html}} =
      :timer.tc(fn ->
        {:ok, view, _html} = live(conn, "/blocks/957600")
        {view, render_async(view, 5_000)}
      end)

    assert micros < 3_000_000
    assert html =~ "957600"
    assert html =~ "We couldn&#39;t load this block&#39;s transactions in time."

    send(holder, :release)
    assert_receive :released, 5_000

    view |> element("#block-txs-unavailable button", "Try again") |> render_click()
    html = render_async(view)

    refute has_element?(view, "#block-txs-unavailable")
    assert html =~ "Transaction IDs not yet synced for this block."
  end

  test "a big completed block pages by txid, with a total from num_tx", %{conn: conn} do
    block_fixture(%{
      height: 635_141,
      hash: "big635141",
      sync_state: "completed",
      num_tx: 3_000_000,
      tx: []
    })

    for txid <- ~w(b_tx a_tx),
        do: transaction_fixture(%{txid: txid, block_hash: "big635141", block_height: 635_141})

    {:ok, view, _html} = live(conn, "/blocks/635141")
    render_async(view)

    assert has_element?(view, "#block-txs-order", "Listed by txid")
    assert has_element?(view, "#block-tx-a_tx")
    assert has_element?(view, "#block-tx-b_tx")
    assert render(view) =~ "1 / 60000"
  end
end
