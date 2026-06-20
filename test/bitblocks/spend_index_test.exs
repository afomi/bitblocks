defmodule Bitblocks.SpendIndexTest do
  use Bitblocks.DataCase

  alias Bitblocks.Chain
  alias Bitblocks.Chain.Spend

  import Bitblocks.ChainFixtures

  # Helper: create a tx whose inputs reference specific outpoints,
  # then record those spends in the spend index.
  # Each entry in `spends` is {prev_txid, prev_vout}.
  defp tx_spending(spends, attrs \\ %{}) do
    inputs =
      spends
      |> Enum.map(fn {prev_txid, prev_vout} ->
        Jason.encode!(%{"txid" => prev_txid, "vout" => prev_vout, "scriptSig" => %{"hex" => "00"}})
      end)

    tx = transaction_fixture(
      Map.merge(%{inputs: inputs, input_count: length(inputs)}, attrs)
    )

    Chain.record_spends(tx)
    tx
  end

  describe "output_spent?/2" do
    test "returns false when no spend recorded" do
      refute Chain.output_spent?("aaa", 0)
    end

    test "returns true after spend is recorded" do
      parent = transaction_fixture(%{output_count: 2})
      _child = tx_spending([{parent.txid, 0}])

      assert Chain.output_spent?(parent.txid, 0)
      refute Chain.output_spent?(parent.txid, 1)
    end
  end

  describe "get_spending_tx/2" do
    test "returns nil for unspent outpoint" do
      assert Chain.get_spending_tx("nonexistent", 0) == nil
    end

    test "returns spend record for spent outpoint" do
      parent = transaction_fixture(%{output_count: 1})
      child = tx_spending([{parent.txid, 0}])

      spend = Chain.get_spending_tx(parent.txid, 0)
      assert %Spend{} = spend
      assert spend.spending_txid == child.txid
      assert spend.spending_vin == 0
    end
  end

  describe "output_spend_statuses/1" do
    test "returns statuses for all outputs" do
      parent = transaction_fixture(%{output_count: 3})
      child = tx_spending([{parent.txid, 1}])

      statuses = Chain.output_spend_statuses(parent.txid)

      assert length(statuses) == 3
      assert Enum.at(statuses, 0) == %{vout: 0, spent: false, spending_txid: nil}
      assert Enum.at(statuses, 1) == %{vout: 1, spent: true, spending_txid: child.txid}
      assert Enum.at(statuses, 2) == %{vout: 2, spent: false, spending_txid: nil}
    end

    test "returns empty list for unknown txid" do
      assert Chain.output_spend_statuses("nonexistent") == []
    end
  end

  describe "record_spends/1" do
    test "records spends from a transaction's inputs" do
      parent_a = transaction_fixture(%{output_count: 2})
      parent_b = transaction_fixture(%{output_count: 1})

      child = tx_spending([{parent_a.txid, 0}, {parent_b.txid, 0}])

      assert Chain.output_spent?(parent_a.txid, 0)
      refute Chain.output_spent?(parent_a.txid, 1)
      assert Chain.output_spent?(parent_b.txid, 0)

      spend = Chain.get_spending_tx(parent_a.txid, 0)
      assert spend.spending_txid == child.txid
      assert spend.spending_vin == 0

      spend_b = Chain.get_spending_tx(parent_b.txid, 0)
      assert spend_b.spending_vin == 1
    end

    test "skips coinbase inputs (all-zero txid)" do
      coinbase_input = Jason.encode!(%{
        "txid" => "0000000000000000000000000000000000000000000000000000000000000000",
        "vout" => 4_294_967_295
      })

      coinbase_tx = transaction_fixture(%{
        inputs: [coinbase_input],
        input_count: 1,
        coinbase: true
      })

      {inserted, _skipped} = Chain.record_spends(coinbase_tx)
      assert inserted == 0
    end

    test "is idempotent — re-recording the same tx is a no-op" do
      parent = transaction_fixture(%{output_count: 1})
      child = tx_spending([{parent.txid, 0}])

      {inserted, _} = Chain.record_spends(child)
      assert inserted == 0
    end
  end

  describe "backfill_spend_index/1" do
    test "populates spend index from existing transactions" do
      parent_a = transaction_fixture(%{output_count: 2})
      parent_b = transaction_fixture(%{output_count: 1})

      # Create a child tx but DON'T let the fixture auto-record spends.
      # Instead, delete existing spend records so backfill has work to do.
      child = tx_spending([{parent_a.txid, 1}, {parent_b.txid, 0}])

      # Clear the spend index
      Repo.delete_all(Spend)
      refute Chain.output_spent?(parent_a.txid, 1)

      # Run backfill
      {:ok, count} = Chain.backfill_spend_index(batch_size: 10)
      assert count >= 2

      # Verify spends are now recorded
      assert Chain.output_spent?(parent_a.txid, 1)
      assert Chain.output_spent?(parent_b.txid, 0)

      spend = Chain.get_spending_tx(parent_a.txid, 1)
      assert spend.spending_txid == child.txid
    end
  end

  describe "spend_depth/1" do
    # Builds a tx with coinbase=true and empty input_txids.
    defp coinbase_tx(attrs \\ %{}) do
      transaction_fixture(Map.merge(%{coinbase: true, input_txids: [], inputs: []}, attrs))
    end

    # Builds a tx that references parent txids in input_txids.
    defp child_tx(parent_txids, attrs \\ %{}) do
      transaction_fixture(Map.merge(%{coinbase: false, input_txids: parent_txids}, attrs))
    end

    test "coinbase transaction has depth 0" do
      cb = coinbase_tx()
      assert Chain.spend_depth(cb.txid) == {:ok, 0}
    end

    test "direct child of coinbase has depth 1" do
      cb = coinbase_tx()
      child = child_tx([cb.txid])
      assert Chain.spend_depth(child.txid) == {:ok, 1}
    end

    test "two hops from coinbase returns depth 2" do
      cb = coinbase_tx()
      hop1 = child_tx([cb.txid])
      hop2 = child_tx([hop1.txid])
      assert Chain.spend_depth(hop2.txid) == {:ok, 2}
    end

    test "takes minimum depth when tx has multiple inputs from different lineages" do
      cb = coinbase_tx()
      # One input is depth 1, other input is depth 2 from coinbase
      hop1 = child_tx([cb.txid])
      hop2 = child_tx([hop1.txid])
      # child spends both hop1 (depth 1) and hop2 (depth 2) — min is 1 + 1 = 2
      child = child_tx([hop1.txid, hop2.txid])
      assert Chain.spend_depth(child.txid) == {:ok, 2}
    end

    test "returns not_found for unknown txid" do
      assert Chain.spend_depth("0000000000000000000000000000000000000000000000000000000000000000") ==
               {:error, :not_found}
    end

    test "vout argument is accepted (depth is per-tx, not per-output)" do
      cb = coinbase_tx()
      child = child_tx([cb.txid])
      assert Chain.spend_depth(child.txid, 0) == {:ok, 1}
      assert Chain.spend_depth(child.txid, 1) == {:ok, 1}
    end
  end
end
