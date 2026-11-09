defmodule Bitblocks.FactsTest do
  # /facts (#70): unclaimed rewards, burned sats and the supply audit, summed
  # from block totals over the blocks complete and totalled, never from txs.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Facts

  @btc 100_000_000

  defp totalled_block(height, opts), do: totalled_block_fixture(height, opts)

  describe "compute/0" do
    test "sums the totals over the blocks complete and totalled, and names the range" do
      # Genesis: completed, with no coinbase row, so no totals of its own.
      block_fixture(%{height: 0, sync_state: "completed"})
      totalled_block(1, fees: 100, burned: 10)
      totalled_block(2, reward: 40 * @btc, burned: 5)
      totalled_block(3, version: nil)
      block_fixture(%{height: 4, sync_state: "header_only"})

      summary = Facts.compute()

      assert summary.status == :ok
      assert summary.through_height == 2
      assert summary.complete_through == 3
      assert summary.tip == 4

      assert summary.issued == 150 * @btc
      assert summary.claimed == 90 * @btc
      assert summary.unclaimed == 10 * @btc
      assert summary.unclaimed_blocks == 1
      assert summary.unspendable == 50 * @btc
      assert [%{height: 0}] = summary.unspendable_coinbases
      assert summary.issued == summary.claimed + summary.unclaimed + summary.unspendable

      assert summary.burned == 15
      assert summary.spendable_at_most == 90 * @btc - 15
      assert summary.fees == 100
      assert summary.mismatched_blocks == 0
      assert [%{height: 2, unclaimed: unclaimed}] = summary.largest_unclaimed
      assert unclaimed == 10 * @btc
    end

    test "counts a tally that claims more than allowed, without hiding it" do
      block_fixture(%{height: 0, sync_state: "completed"})
      totalled_block(1, reward: 51 * @btc, verified: false)

      summary = Facts.compute()

      assert summary.through_height == 1
      assert summary.mismatched_blocks == 1
      assert summary.unclaimed == -1 * @btc
    end

    test "covers nothing until block 0 is complete" do
      block_fixture(%{height: 0, sync_state: "header_only"})

      summary = Facts.compute()

      assert summary.through_height == -1
      refute Map.has_key?(summary, :issued)
    end
  end

  test "issued_through/1 follows the halving schedule" do
    assert Facts.issued_through(-1) == 0
    assert Facts.issued_through(0) == 50 * @btc
    assert Facts.issued_through(209_999) == 210_000 * 50 * @btc
    assert Facts.issued_through(210_000) == 210_000 * 50 * @btc + 25 * @btc
    # The 21 million cap, less what integer halving rounds away.
    assert Facts.issued_through(64 * 210_000) == 2_099_999_997_690_000
  end
end
