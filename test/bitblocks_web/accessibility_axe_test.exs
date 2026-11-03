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

    test "reorgs page is accessible with no reorgs recorded", %{session: session} do
      session
      |> visit("/reorgs")
      |> assert_no_violations()
    end

    test "reorgs page is accessible with recorded reorgs, in light mode", %{session: session} do
      record_reorgs()

      session
      |> visit("/reorgs")
      |> assert_has(css("#reorg-notice"))
      |> assert_no_violations()
    end

    test "reorgs page is accessible with recorded reorgs, in dark mode", %{session: session} do
      record_reorgs()

      session
      |> visit("/reorgs")
      |> execute_script(
        "document.documentElement.classList.remove('light'); document.documentElement.classList.add('dark');"
      )
      |> assert_has(css("html.dark"))
      |> assert_has(css("#reorg-notice"))
      |> assert_no_violations()
    end
  end

  # One fresh reorg per outcome, so the banner and both timeline labels render.
  defp record_reorgs do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      Bitblocks.Reorgs.record_observed(
        %{fork_height: 800_000, fork_point: 799_998, orphan_count: 2, outcome: "resolved"},
        now
      )

    {:ok, _} =
      Bitblocks.Reorgs.record_observed(
        %{fork_height: 800_010, fork_point: nil, orphan_count: nil, outcome: "needs_attention"},
        now
      )
  end
end
