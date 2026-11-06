defmodule BitblocksWeb.NoDeleteEventsTest do
  # /blocks is public and /transactions is open to any signed-in user, and a
  # LiveView event needs no button: a client can push any event name over its
  # socket. Chain rows come from the chain, so neither page may delete one.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Repo

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "a pushed delete on /blocks removes nothing", %{conn: conn} do
    block = block_fixture()
    {:ok, view, _html} = live(conn, ~p"/blocks")

    catch_exit(render_click(view, "delete", %{"id" => to_string(block.height)}))

    assert Repo.get(Block, block.id)
  end

  test "a pushed delete on /transactions removes nothing", %{conn: conn} do
    block = block_fixture()
    tx = transaction_fixture(%{block_hash: block.hash, block_height: block.height})
    {:ok, view, _html} = live(conn, ~p"/transactions")

    catch_exit(render_click(view, "delete", %{"id" => tx.txid}))

    assert Repo.get(Transaction, tx.id)
  end
end
