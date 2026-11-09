defmodule Bitblocks.ScriptLocksTest do
  # #76: the time locks in an output's script, as found.
  #
  # The 1Sat Lock cases read real HodLocker txs (test/support/data/hodlocker_txs.json,
  # each checked against its txid). No real bare CLTV, CSV or conditional lock
  # was found to pin (the dev chain holds none, and a P2SH lock shows only in its
  # spend), so those cases are scripts built here from the opcode structure, and
  # serialized and parsed back from bytes the way the pipeline reads them.
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.RawTx
  alias Bitblocks.ScriptLocks

  @txs "test/support/data/hodlocker_txs.json"
       |> File.read!()
       |> Jason.decode!()
       |> Map.fetch!("txs")
       |> Map.new(&{&1["txid"], &1})

  @like "7f496c643364501f7b1c3f1593fd827b6e2af7207b3ead3ec04bb5666c16a88b"
  @owner "13PnV1oUFYAeMUzzvoKFWX9FpjnMxyUpM9"

  @pkh :binary.copy(<<0x11>>, 20)
  @pubkey <<0x02>> <> :binary.copy(<<0x22>>, 32)
  @p2pkh [:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]

  # Through bytes and back, so byte 177 gets whichever name the decoder gives it.
  defp script(chunks) do
    bytes = BSV.Script.to_binary(%BSV.Script{chunks: chunks})
    RawTx.script(bytes)
  end

  # A positive script number: a 0x00 byte keeps a high top bit from reading as the sign.
  defp num(n) do
    bytes = :binary.encode_unsigned(n, :little)
    if :binary.last(bytes) >= 0x80, do: bytes <> <<0>>, else: bytes
  end

  describe "a 1Sat Lock (real HodLocker txs)" do
    test "a like's lock: owner, unlock height, enforced, on every path" do
      {:ok, tx} = RawTx.parse(@txs[@like]["raw"])

      assert [
               %{
                 vout: 0,
                 kind: "1sat_lock",
                 satoshis: 2_100_000_000,
                 unlock_height: 858_404,
                 owner: @owner,
                 enforced: true,
                 conditional: false,
                 branch: nil
               }
             ] = ScriptLocks.tx_locks(tx, @txs[@like]["height"])
    end

    test "every HodLocker fixture's lock is found, and nothing in its data output" do
      for {txid, %{"raw" => raw, "height" => height}} <- @txs do
        {:ok, tx} = RawTx.parse(raw)
        locks = ScriptLocks.tx_locks(tx, height)
        assert locks != [], "no lock in #{txid}"
        assert Enum.all?(locks, &(&1.kind == "1sat_lock" and &1.enforced))
      end
    end
  end

  describe "CLTV" do
    @cltv_p2pkh [
      :binary.encode_unsigned(500_100, :little),
      :OP_CHECKLOCKTIMEVERIFY,
      :OP_DROP | @p2pkh
    ]

    test "binds for an output mined after BIP 65 and before Genesis" do
      assert [
               %{
                 kind: "cltv",
                 lock_value: 500_100,
                 unlock_height: 500_100,
                 enforced: true,
                 conditional: false,
                 relative: false
               }
             ] = ScriptLocks.output_locks(script(@cltv_p2pkh), 500_000)
    end

    test "is a NOP after Genesis, and before BIP 65" do
      assert [%{kind: "cltv", enforced: false}] =
               ScriptLocks.output_locks(script(@cltv_p2pkh), ScriptLocks.genesis_height())

      assert [%{enforced: false}] = ScriptLocks.output_locks(script(@cltv_p2pkh), 380_000)
      assert [%{enforced: nil}] = ScriptLocks.output_locks(script(@cltv_p2pkh), nil)
    end

    test "a value from 500,000,000 on is a unix time" do
      chunks = [num(1_500_000_000), :OP_CHECKLOCKTIMEVERIFY, :OP_DROP | @p2pkh]

      assert [%{unlock_height: nil, unlock_time: ~U[2017-07-14 02:40:00Z]}] =
               ScriptLocks.output_locks(script(chunks), 450_000)
    end

    test "a small height pushed as OP_N is read, and a computed value is noted" do
      assert [%{lock_value: 5, unlock_height: 5}] =
               ScriptLocks.output_locks(
                 script([:OP_5, :OP_CHECKLOCKTIMEVERIFY, :OP_DROP | @p2pkh]),
                 500_000
               )

      assert [%{lock_value: nil, unlock_height: nil, notes: "The value is computed" <> _}] =
               ScriptLocks.output_locks(
                 script([:OP_DUP, :OP_CHECKLOCKTIMEVERIFY, :OP_DROP | @p2pkh]),
                 500_000
               )
    end
  end

  describe "conditional: a lock on one branch" do
    test "an IF lock with a cosigner ELSE is locked on one path" do
      chunks =
        [:OP_IF, num(500_100), :OP_CHECKLOCKTIMEVERIFY, :OP_DROP] ++
          @p2pkh ++ [:OP_ELSE, @pubkey, :OP_CHECKSIG, :OP_ENDIF]

      assert [%{kind: "cltv", conditional: true, branch: "OP_IF", enforced: true}] =
               ScriptLocks.output_locks(script(chunks), 500_000)
    end

    test "a lock in the ELSE branch names that branch" do
      chunks =
        [:OP_IF, @pubkey, :OP_CHECKSIG, :OP_ELSE, num(500_100), :OP_CHECKLOCKTIMEVERIFY] ++
          [:OP_DROP | @p2pkh] ++ [:OP_ENDIF]

      assert [%{conditional: true, branch: "OP_ELSE"}] =
               ScriptLocks.output_locks(script(chunks), 500_000)
    end

    test "an IF with no ELSE can skip the lock, so it's conditional too" do
      chunks = [:OP_IF, num(500_100), :OP_CHECKLOCKTIMEVERIFY, :OP_DROP, :OP_ENDIF | @p2pkh]

      assert [%{conditional: true, branch: "OP_IF"}] =
               ScriptLocks.output_locks(script(chunks), 500_000)
    end

    test "a nested lock gives its whole path" do
      chunks =
        [:OP_IF, @pubkey, :OP_CHECKSIG, :OP_ELSE, :OP_NOTIF, num(500_100)] ++
          [:OP_CHECKLOCKTIMEVERIFY, :OP_DROP, :OP_ENDIF, :OP_ENDIF | @p2pkh]

      assert [%{conditional: true, branch: "OP_ELSE > OP_NOTIF"}] =
               ScriptLocks.output_locks(script(chunks), 500_000)
    end

    test "a sibling branch that can never spend doesn't make the lock conditional" do
      chunks =
        [:OP_IF, num(500_100), :OP_CHECKLOCKTIMEVERIFY, :OP_DROP] ++
          [:OP_ELSE, :OP_RETURN, :OP_ENDIF | @p2pkh]

      assert [%{conditional: false, branch: "OP_IF"}] =
               ScriptLocks.output_locks(script(chunks), 500_000)
    end

    test "byte 177 inside an inscription envelope is data, not a lock" do
      chunks =
        @p2pkh ++
          [:OP_FALSE, :OP_IF, "ord", :OP_1, "text/plain", :OP_CHECKLOCKTIMEVERIFY, :OP_ENDIF]

      assert ScriptLocks.output_locks(script(chunks), 500_000) == []
    end
  end

  describe "CSV" do
    test "a relative lock of blocks counts from the output's block" do
      chunks = [num(144), :OP_CHECKSEQUENCEVERIFY, :OP_DROP | @p2pkh]

      assert [%{kind: "csv", relative: true, unlock_height: 500_144, enforced: true}] =
               ScriptLocks.output_locks(script(chunks), 500_000)

      # Before BIP 112, byte 178 was still a NOP.
      assert [%{enforced: false}] = ScriptLocks.output_locks(script(chunks), 410_000)
    end

    test "a time-based relative lock counts 512-second units from the block's time" do
      chunks = [num(0x00400000 + 2), :OP_CHECKSEQUENCEVERIFY, :OP_DROP | @p2pkh]

      assert [%{unlock_height: nil, unlock_time: ~U[2017-01-01 00:17:04Z]}] =
               ScriptLocks.output_locks(script(chunks), 450_000, 1_483_228_800)
    end

    test "the disable flag means no lock" do
      chunks = [<<0, 0, 0, 0x80, 0>>, :OP_CHECKSEQUENCEVERIFY, :OP_DROP | @p2pkh]
      assert [%{kind: "csv", enforced: false}] = ScriptLocks.output_locks(script(chunks), 450_000)
    end
  end

  test "data outputs and ordinary locks hold none" do
    assert ScriptLocks.output_locks(script(@p2pkh), 500_000) == []

    assert ScriptLocks.output_locks(
             script([:OP_FALSE, :OP_RETURN, "x", :OP_CHECKLOCKTIMEVERIFY]),
             500_000
           ) == []
  end
end
