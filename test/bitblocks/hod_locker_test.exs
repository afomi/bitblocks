defmodule Bitblocks.HodLockerTest do
  # #75: what a HodLocker tx's time locks back, read from real txs
  # (test/support/data/hodlocker_txs.json, each checked against its txid).
  use ExUnit.Case, async: true

  alias Bitblocks.{HodLocker, TimeLock}
  alias Bitblocks.Chain.RawTx
  alias Bitblocks.TxTypes.Classifier

  @txs "test/support/data/hodlocker_txs.json"
       |> File.read!()
       |> Jason.decode!()
       |> Map.fetch!("txs")
       |> Map.new(&{&1["txid"], &1["raw"]})

  @post "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
  @like "7f496c643364501f7b1c3f1593fd827b6e2af7207b3ead3ec04bb5666c16a88b"
  @reply "eafe28415397d046c7066441e3f9fe0f16d4be85010e45321fce0df42ec5541c"
  @owner "13PnV1oUFYAeMUzzvoKFWX9FpjnMxyUpM9"

  defp tx(txid) do
    {:ok, tx} = RawTx.parse(Map.fetch!(@txs, txid))
    tx
  end

  describe "parse/2" do
    test "a like: its lock backs the post it names" do
      assert %{
               kind: :like,
               post_txid: @post,
               reply_to: nil,
               locks: [%{vout: 0, satoshis: 2_100_000_000, owner: @owner, unlock_height: 858_404}]
             } = HodLocker.parse(tx(@like), @like)
    end

    test "a post: its lock backs the post itself, with the author's paymail" do
      assert %{
               kind: :post,
               post_txid: @post,
               paymail: "jack@relayx.io",
               locks: [%{vout: 0, satoshis: 1, unlock_height: 833_548}]
             } = HodLocker.parse(tx(@post), @post)
    end

    test "a reply: a post that names the post it answers" do
      assert %{
               kind: :reply,
               post_txid: @reply,
               reply_to: "11b165c93245eaa73ff5af5a7b63c56ea16b8a14bf596520cff855d96775aa11",
               locks: [%{satoshis: 1, unlock_height: 834_147}]
             } = HodLocker.parse(tx(@reply), @reply)
    end

    test "a tx with no HodLocker record is nil" do
      payment = %BSV.Tx{
        inputs: [],
        outputs: [
          %BSV.TxOut{
            satoshis: 5,
            script: %BSV.Script{
              chunks: [
                :OP_FALSE,
                :OP_RETURN,
                "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
                "SET",
                "app",
                "other"
              ]
            }
          }
        ]
      }

      assert HodLocker.parse(payment, String.duplicate("0", 64)) == nil
    end
  end

  test "every HodLocker tx is typed hodlocker, beside its lock and its data" do
    assert %{types: types} = Classifier.classify(tx(@like))
    assert "hodlocker" in types and "timelock" in types and "map" in types

    for txid <- [@post, @reply] do
      assert %{types: types} = Classifier.classify(tx(txid))
      assert "hodlocker" in types and "timelock" in types and "b" in types
    end
  end

  describe "TimeLock.parse/1" do
    test "the shared vector: an address locked until block 900,000" do
      vector =
        "priv/data/tx_types/output_types_v1.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("vectors")
        |> Enum.find(&(&1["name"] == "lock_timelock"))

      script = BSV.Script.from_binary!(vector["script_hex"], encoding: :hex)

      assert {:ok, %{owner: "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH", unlock_height: 900_000}} =
               TimeLock.parse(script)
    end

    test "a script that isn't a time lock is :error" do
      assert TimeLock.parse(%BSV.Script{chunks: [:OP_1]}) == :error
    end
  end
end
