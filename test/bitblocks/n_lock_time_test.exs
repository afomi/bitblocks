defmodule Bitblocks.NLockTimeTest do
  # #76: a tx's own lock time, read from real txs (tx_vectors.json).
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.RawTx
  alias Bitblocks.NLockTime

  @vectors "priv/data/tx_types/tx_vectors.json"
           |> File.read!()
           |> Jason.decode!()
           |> Map.fetch!("vectors")
           |> Map.new(&{&1["name"], &1})

  defp tx(name) do
    {:ok, tx} = RawTx.parse(@vectors[name]["raw"])
    tx
  end

  test "an enforced height lock: lock time 399,988 and a sequence of 0xfffffffe" do
    assert %{lock_time: 399_988, kind: :height, enforced: true, unlock_height: 399_988} =
             NLockTime.parse(tx("tx_nlocktime_anti_fee_sniping"))
  end

  test "a lock time with every input final is read, but not enforced" do
    assert %{lock_time: 973_899, kind: :height, enforced: false} =
             NLockTime.parse(tx("tx_nlocktime_ignored"))

    refute NLockTime.enforced?(tx("tx_nlocktime_ignored"))
  end

  test "lock time 0 is no lock" do
    assert NLockTime.parse(%BSV.Tx{lock_time: 0, inputs: [%BSV.TxIn{sequence: 0}]}) == nil
    refute NLockTime.enforced?(%BSV.Tx{lock_time: 0, inputs: [%BSV.TxIn{sequence: 0}]})
  end

  test "from 500,000,000 on, the lock time is a unix time" do
    tx = %BSV.Tx{lock_time: 1_700_000_000, inputs: [%BSV.TxIn{sequence: 0}]}

    assert %{kind: :time, unlock_height: nil, unlock_time: ~U[2023-11-14 22:13:20Z]} =
             NLockTime.parse(tx)

    assert %{kind: :height} = NLockTime.parse(%{tx | lock_time: 499_999_999})
  end

  describe "near_tip?/2 and typed?/2: the anti-fee-sniping shape" do
    test "a wallet's lock 12 blocks below the block it was mined in is near the tip" do
      tx = tx("tx_nlocktime_anti_fee_sniping")
      block = %{height: 400_000, time: 1_456_417_484}

      assert %{enforced: true, near_tip: true} = NLockTime.parse(tx, block)
      refute NLockTime.typed?(tx, block)
    end

    test "the window is 2,016 blocks, or 14 days for a time" do
      assert NLockTime.near_tip?(897_984, %{height: 900_000})
      refute NLockTime.near_tip?(897_983, %{height: 900_000})

      assert NLockTime.near_tip?(1_700_000_000, %{time: 1_700_000_000 + 14 * 86_400})
      refute NLockTime.near_tip?(1_700_000_000, %{time: 1_700_000_001 + 14 * 86_400})
    end

    test "without the block's height or time it can't say" do
      assert NLockTime.near_tip?(800_000, nil) == nil
      assert NLockTime.near_tip?(800_000, %{height: nil, time: 1}) == nil
      assert %{near_tip: nil} = NLockTime.parse(tx("tx_nlocktime_anti_fee_sniping"))
      refute NLockTime.typed?(tx("tx_nlocktime_anti_fee_sniping"), nil)
    end
  end

  describe "state/3" do
    test "a height lock is reached once our tip is at it" do
      lock = NLockTime.parse(tx("tx_nlocktime_anti_fee_sniping"))

      assert NLockTime.state(lock, 399_988, nil) == :reached
      assert NLockTime.state(lock, 399_980, nil) == {:waiting, 8}
      assert NLockTime.state(lock, nil, nil) == :unknown
    end

    test "a time lock is compared with the tip block's time" do
      lock = NLockTime.parse(%BSV.Tx{lock_time: 1_700_000_000, inputs: [%BSV.TxIn{sequence: 0}]})

      assert NLockTime.state(lock, 1, ~U[2023-11-15 00:00:00Z]) == :reached
      assert NLockTime.state(lock, 1, ~U[2023-11-14 00:00:00Z]) == :waiting
      assert NLockTime.state(lock, 1, nil) == :unknown
    end
  end
end
