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
             NLockTime.parse(tx("tx_nlocktime_enforced"))
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

  describe "state/3" do
    test "a height lock is reached once our tip is at it" do
      lock = NLockTime.parse(tx("tx_nlocktime_enforced"))

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
