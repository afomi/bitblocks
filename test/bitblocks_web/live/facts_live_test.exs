defmodule BitblocksWeb.FactsLiveTest do
  # /facts (#70). The LiveView reads the cached figures, which the test refreshes.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures
  import Phoenix.LiveViewTest

  alias Bitblocks.Facts

  @btc 100_000_000

  setup do
    on_exit(fn -> :ets.delete(Facts, :summary) end)
    :ok
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
  end

  test "shows the exact sums on fixture blocks and names the range", %{conn: conn} do
    block_fixture(%{height: 0, sync_state: "completed"})
    totalled_block_fixture(1, fees: 100, burned: 12_345)
    totalled_block_fixture(2, reward: 4_250_000_000)
    block_fixture(%{height: 3, sync_state: "completed"})
    Facts.refresh()

    {:ok, view, _html} = live(conn, ~p"/facts")

    assert text(view, "#facts-coverage") =~ "These figures cover blocks 0 to 2 of 3 known."

    assert text(view, "#facts-coverage") =~
             "Blocks 3 to 3 are complete and waiting for their totals."

    assert text(view, "#facts-unclaimed-total") =~ "7.5 BSV"
    assert text(view, "#facts-unclaimed") =~ "750,000,000 sats"
    assert text(view, "#facts-unclaimed") =~ "left in 1 blocks"
    assert has_element?(view, "#facts-largest-unclaimed a[href='/blocks/2']", "2")

    assert text(view, "#facts-burned-total") =~ "0.00012345 BSV"
    assert text(view, "#facts-issued") =~ "150 BSV"
    assert text(view, "#facts-claimed") =~ "92.5 BSV"
    assert text(view, "#facts-unspendable") =~ "50 BSV"
    assert text(view, "#facts-spendable") =~ "92.49987655 BSV"
    refute has_element?(view, "#facts-mismatch")

    assert has_element?(view, "#facts-unspendable-coinbases a[href='/blocks/91812']")
  end

  test "warns when a tally says a miner took more than allowed", %{conn: conn} do
    block_fixture(%{height: 0, sync_state: "completed"})
    totalled_block_fixture(1, reward: 51 * @btc, verified: false)
    Facts.refresh()

    {:ok, view, _html} = live(conn, ~p"/facts")

    assert text(view, "#facts-mismatch") =~ "In 1 blocks"
  end

  test "before any block is complete, says so and shows no figures", %{conn: conn} do
    block_fixture(%{height: 0, sync_state: "header_only"})
    Facts.refresh()

    {:ok, view, _html} = live(conn, ~p"/facts")

    assert text(view, "#facts-coverage") =~ "No block is verified complete yet"
    refute has_element?(view, "#facts-unclaimed")
  end

  test "before the first refresh, says the figures are being computed", %{conn: conn} do
    :ets.delete(Facts, :summary)

    {:ok, view, _html} = live(conn, ~p"/facts")

    assert text(view, "#facts-coverage") =~ "being computed"
    assert has_element?(view, "#facts-unspendable-coinbases")
  end
end
