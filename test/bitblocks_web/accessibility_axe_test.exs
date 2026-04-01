defmodule BitblocksWeb.AccessibilityAxeTest do
  use BitblocksWeb.AccessibilityFeatureCase, async: false
  import Bitblocks.ChainFixtures

  @moduletag :accessibility_axe

  describe "accessibility scanning with axe-core" do
    test "home page is accessible", %{session: session} do
      session
      |> visit("/")
      |> assert_no_violations()
    end

    test "status page is accessible", %{session: session} do
      session
      |> visit("/status")
      |> assert_no_violations()
    end

    test "blocks index page is accessible", %{session: session} do
      session
      |> visit("/blocks")
      |> assert_no_violations()
    end

    test "block show page is accessible", %{session: session} do
      block = block_fixture()

      session
      |> visit("/blocks/#{block.height}")
      |> assert_no_violations()
    end

    test "transactions index page is accessible", %{session: session} do
      session
      |> visit("/transactions")
      |> assert_no_violations()
    end

    test "transaction show page is accessible", %{session: session} do
      block = block_fixture()
      transaction = transaction_fixture(%{block_height: block.height})

      session
      |> visit("/transactions/#{transaction.txid}")
      |> assert_no_violations()
    end

    test "sync page is accessible", %{session: session} do
      session
      |> visit("/sync")
      |> assert_no_violations()
    end

    test "protocols page is accessible", %{session: session} do
      session
      |> visit("/protocols")
      |> assert_no_violations()
    end

    test "graph page is accessible", %{session: session} do
      session
      |> visit("/graph")
      |> assert_no_violations()
    end

    test "highlights page is accessible", %{session: session} do
      session
      |> visit("/highlights")
      |> assert_no_violations()
    end

    test "search page is accessible", %{session: session} do
      session
      |> visit("/search")
      |> assert_no_violations()
    end

    test "config page is accessible", %{session: session} do
      session
      |> visit("/config")
      |> assert_no_violations()
    end
  end
end
