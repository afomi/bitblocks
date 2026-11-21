defmodule Bitblocks.Chain.UtxosTest do
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  import Bitblocks.OrdinalFixtures,
    only: [address: 0, p2pkh: 2, tx: 2, data_output: 0, contract: 0]

  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, RawBlock, RawTx, Spend, Transaction, TxIngest, Utxos}
  alias Bitblocks.FirstSpendFixtures, as: FS

  import ExUnit.CaptureLog

  # Block 9's coinbase pays this key's P2PK; block 170's first spend sends 10
  # coins to Hal Finney and 40 back to the same key.
  @satoshi "12cbQLTFMXRnSzktFkuoG3eHoMeFtpTu3S"
  @fifty 5_000_000_000
  @forty 4_000_000_000

  defp store({txid, hex}, height) do
    block = Repo.get_by!(Block, height: height)
    :ok = TxIngest.store(RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed)), block)
    txid
  end

  # Block 170 as a header we hold but haven't synced: its txs and the spend
  # they recorded aren't stored yet.
  defp unsync_block_170 do
    Repo.delete_all(from(t in Transaction, where: t.block_height == 170))
    Repo.delete_all(from(s in Spend, where: s.spending_txid == ^FS.first_spend()))
    Repo.update_all(from(b in Block, where: b.height == 170), set: [sync_state: "header_only"])
  end

  describe "the first spend, fully synced" do
    setup do
      FS.insert_first_spend()
      completed_chain_fixture(170)
      :ok
    end

    test "the spent coinbase is spent, by the tx the spend index names" do
      assert {:ok, %{status: :spent, spent_by: spender, spent_by_vin: 0, address: @satoshi}} =
               Utxos.outpoint(FS.coinbase_9(), 0)

      assert spender == Repo.one(from(s in Spend, select: s.spending_txid))
    end

    test "a tx row stored without block_height reports its block's height" do
      Repo.update_all(from(t in Transaction, where: t.txid == ^FS.coinbase_9()),
        set: [block_height: nil]
      )

      assert {:ok, %{status: :spent, block_height: 9}} = Utxos.outpoint(FS.coinbase_9(), 0)
    end

    test "the balance is exact, through the tip, in satoshis read from the raw txs" do
      assert %{
               status: :exact,
               confirmed: @forty,
               indexed_through_height: 170,
               tip_height: 170
             } = balance = Utxos.balance(@satoshi)

      refute Map.has_key?(balance, :unknown)

      assert [
               %{txid: cb, vout: 0, satoshis: @fifty, status: :spent},
               %{txid: change, vout: 1, satoshis: @forty, status: :unspent}
             ] = Utxos.for_address(@satoshi).outputs

      assert cb == FS.coinbase_9()
      assert change == FS.first_spend()
    end
  end

  describe "a spend in a block that isn't synced yet" do
    setup do
      FS.insert_first_spend()
      completed_chain_fixture(170)
      unsync_block_170()
      :ok
    end

    test "leaves the output unknown, not unspent" do
      assert {:ok, %{status: :unknown, spent_by: nil}} = Utxos.outpoint(FS.coinbase_9(), 0)

      assert %{
               outputs: [%{vout: 0, status: :unknown}],
               indexed_through_height: 169,
               tip_height: 170
             } =
               Chain.output_status(FS.coinbase_9())
    end

    test "makes the balance partial, with no confirmed number" do
      balance = Utxos.balance(@satoshi)

      assert %{status: :partial, unknown: @fifty, indexed_through_height: 169, tip_height: 170} =
               balance

      refute Map.has_key?(balance, :confirmed)
    end
  end

  test "with nothing indexed from genesis the balance is unknown" do
    FS.insert_first_spend()

    assert %{status: :unknown, indexed_through_height: -1, tip_height: 170} =
             balance = Utxos.balance(@satoshi)

    refute Map.has_key?(balance, :confirmed)
  end

  describe "exact satoshis" do
    setup do
      completed_chain_fixture(5)
      :ok
    end

    test "a non-dyadic BSV value matches the integer in the raw tx" do
      addr = address()
      # 0.10000001 BSV and 1234.56789012 BSV have no exact binary float.
      {txid, hex} =
        t = tx([funding_outpoint()], [p2pkh(addr, 10_000_001), p2pkh(addr, 123_456_789_012)])

      store(t, 5)

      {:ok, %{outputs: [{a, _}, {b, _}]}} = RawTx.flows(hex)
      assert {a, b} == {10_000_001, 123_456_789_012}

      # The stored RPC-shaped JSON no longer decides the amount.
      Repo.update_all(from(x in Transaction, where: x.txid == ^txid),
        set: [outputs: [~s({"value":0.1}), ~s({"value":1234.5678})]]
      )

      assert [%{satoshis: ^a}, %{satoshis: ^b}] = Utxos.for_address(addr).outputs
      assert %{status: :exact, confirmed: 123_466_789_013} = Utxos.balance(addr)
      assert {:ok, %{satoshis: ^a}} = Utxos.outpoint(txid, 0)
    end
  end

  describe "outputs with no address" do
    setup do
      completed_chain_fixture(5)
      :ok
    end

    test "are left out of the address's outputs and balance" do
      addr = address()
      t = tx([funding_outpoint()], [data_output(), p2pkh(addr, 700), contract()])
      txid = store(t, 5)

      assert %{status: :exact, confirmed: 700} = Utxos.balance(addr)
      assert [%{txid: ^txid, vout: 1}] = Utxos.for_address(addr).outputs
    end
  end

  describe "canonical" do
    setup do
      completed_chain_fixture(5)
      :ok
    end

    test "a spend by a tx whose block we don't store is unknown" do
      addr = address()
      {txid, _} = t = tx([funding_outpoint()], [p2pkh(addr, 1_000)])
      store(t, 5)

      # The spender sits in an orphaned block (its row was replaced in a reorg).
      orphan = %Block{hash: "orphan-5", height: 5}
      s = tx(["#{txid}_0"], [p2pkh(address(), 900)])

      :ok =
        TxIngest.store(
          RawBlock.tx_json(elem(s, 0), Base.decode16!(elem(s, 1), case: :mixed)),
          orphan
        )

      assert {:ok, %{status: :unknown}} = Utxos.outpoint(txid, 0)
      assert %{status: :partial, unknown: 1_000} = Utxos.balance(addr)
    end

    test "spend rows come from spend_index; the block check is a capped second query" do
      addr = address()
      {txid, _} = t = tx([funding_outpoint()], [p2pkh(addr, 1_000)])
      store(t, 5)
      store(tx(["#{txid}_0"], [p2pkh(address(), 900)]), 5)

      parent = self()
      handler = "utxo-sql-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:bitblocks, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          send(parent, {:sql, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{status: :spent}} = Utxos.outpoint(txid, 0)

      sql = sql_from_self([])

      spend = Enum.find(sql, &(&1 =~ "spend_index"))
      assert spend =~ "spending_txid"
      refute spend =~ "transactions"

      assert "SET LOCAL statement_timeout = 2000" in sql

      assert Enum.any?(sql, fn statement ->
               statement =~ "FROM \"transactions\"" and statement =~ "JOIN \"blocks\""
             end)
    end

    test "a block check Postgres cancels leaves the spend unknown, and the connection survives" do
      addr = address()
      {txid, _} = t = tx([funding_outpoint()], [p2pkh(addr, 1_000)])
      store(t, 5)
      store(tx(["#{txid}_0"], [p2pkh(address(), 900)]), 5)

      assert {:ok, %{status: :spent}} = Utxos.outpoint(txid, 0)

      # This connection only: every read of transactions sleeps, then the
      # sandbox rollback drops the view with the test.
      Repo.query!("""
      CREATE TEMP VIEW transactions AS
      SELECT * FROM public.transactions WHERE pg_sleep(0.2)::text = ''
      """)

      Application.put_env(:bitblocks, :utxo_spender_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:bitblocks, :utxo_spender_timeout_ms) end)

      log =
        capture_log(fn ->
          assert {:ok, %{status: :unknown, spent_by: nil}} = Utxos.outpoint(txid, 0)
        end)

      assert log =~ "Utxos spend canonicality timed out for 1 spender(s)"
      assert %{rows: [[1]]} = Repo.query!("SELECT 1")
    end

    test "an output in a tx whose block we don't store is unknown" do
      addr = address()
      {txid, hex} = tx([funding_outpoint()], [p2pkh(addr, 1_000)])

      :ok =
        TxIngest.store(RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed)), %Block{
          hash: "orphan",
          height: 4
        })

      assert {:ok, %{status: :unknown}} = Utxos.outpoint(txid, 0)
      assert %{status: :partial, unknown: 1_000} = Utxos.balance(addr)
    end
  end

  describe "by scripthash" do
    test "is exact only through the tip, like an address" do
      completed_chain_fixture(5)
      addr = address()
      out = p2pkh(addr, 2_500)
      t = tx([funding_outpoint()], [out])
      txid = store(t, 5)
      hash = Bitblocks.Script.script_hash(out.script)

      assert %{status: :exact, outputs: [%{txid: ^txid, satoshis: 2_500, status: :unspent}]} =
               Utxos.for_script_hash(hash)

      block_fixture(%{height: 6, sync_state: "header_only"})

      assert %{status: :partial, indexed_through_height: 5, outputs: [%{status: :unknown}]} =
               Utxos.for_script_hash(hash)
    end
  end

  defp funding_outpoint, do: Bitblocks.OrdinalFixtures.funding_outpoint()

  defp sql_from_self(acc) do
    receive do
      {:sql, query} -> sql_from_self([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
