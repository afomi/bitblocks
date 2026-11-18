defmodule Bitblocks.RestoreCheckTest do
  # The numbers infra compares between a source database and its restore
  # (docs/RESTORE.md, https://github.com/afomi/bitblocks/issues/55).
  use Bitblocks.DataCase

  import Bitblocks.ChainFixtures
  import ExUnit.CaptureIO

  alias Bitblocks.Chain.Block
  alias Bitblocks.RealHeaders
  alias Bitblocks.Release
  alias Bitblocks.RestoreCheck
  alias Bitblocks.TxStore

  # Any bytes do: a row's txid is what they hash to.
  @raw_1 "01000000" <> String.duplicate("ab", 60)
  @raw_2 "02000000" <> String.duplicate("cd", 60)

  setup do
    for h <- [0, 1, 2], do: RealHeaders.insert(h, %{sync_state: "completed"})

    tx_1 = tx_at(1, @raw_1)
    tx_2 = tx_at(2, @raw_2)
    # Above the compared height: never counted, never sampled.
    RealHeaders.insert(9, %{sync_state: "header_only"})
    transaction_fixture(%{block_height: 9, raw: @raw_1 <> "00"})

    %{tx_1: tx_1, tx_2: tx_2}
  end

  defp tx_at(height, raw) do
    txid = raw |> Base.decode16!(case: :lower) |> TxStore.txid()

    transaction_fixture(%{
      txid: txid,
      raw: raw,
      block_height: height,
      block_hash: RealHeaders.fields(height).hash
    })
  end

  test "a whole database reads complete through 2, every header good, every sample hashing" do
    r = RestoreCheck.run(sample: 10)

    assert r.ok, inspect(r.failures)
    assert r.tip == 9
    assert r.complete_through == 2
    assert r.through == 2
    assert r.chain.blocks == 3
    assert r.bounded["blocks"].total == 3
    # raw is hex text: 128 characters each.
    assert r.bounded["transactions"] == %{
             total: 2,
             raw_rows: 2,
             raw_bytes: 256,
             buckets: [%{from: 0, rows: 2, raw_rows: 2, raw_bytes: 256}]
           }

    assert r.bounded["blocks"].raw_rows == false
    assert r.unbounded["users"] == 0
    assert r.unbounded["spend_index"] == 0
    assert r.headers == %{checked: 3, verified: 3, canonical: 3, missing: 0, bad: []}
    assert r.sample == %{checked: 2, ok: 2, from_store: 0, bad: []}
    assert r.database.name =~ "bitblocks_test"
  end

  test "the chain digest and fingerprint are the hashes of their stated text" do
    r = RestoreCheck.run(sample: 0)

    chain_text =
      for h <- [0, 1, 2], into: "", do: "#{h}:#{RealHeaders.fields(h).hash}\n"

    assert r.chain.digest == sha256(chain_text)
    text = RestoreCheck.fingerprint_text(2, r.chain, r.bounded)
    assert text =~ "transactions=2\ntransactions.raw_rows=2\ntransactions.raw_bytes=256\n"
    assert r.fingerprint == sha256(text)
    assert r.full_fingerprint == sha256(text <> RestoreCheck.unbounded_text(r.unbounded))
    assert RestoreCheck.unbounded_text(r.unbounded) =~ "spend_index=0\n"
  end

  test "the full fingerprint sees a table without a height; estimates give none" do
    before = RestoreCheck.run(sample: 0)

    Repo.insert!(%Bitblocks.Chain.Spend{
      txid: "prev",
      vout: 0,
      spending_txid: "x",
      spending_vin: 0
    })

    later = RestoreCheck.run(sample: 0)

    assert later.fingerprint == before.fingerprint
    refute later.full_fingerprint == before.full_fingerprint
    assert RestoreCheck.run(sample: 0, unbounded: :estimate).full_fingerprint == nil
  end

  test "a row that lost its raw changes the fingerprint and fails the sample, even with the bytes in the store",
       %{tx_2: tx_2} do
    before = RestoreCheck.run(sample: 0)
    # The store holds the true bytes: the check must not borrow them.
    :ok = TxStore.put(tx_2.txid, Base.decode16!(@raw_2, case: :lower))
    set_raw(tx_2.txid, nil)

    r = RestoreCheck.run(sample: 10)

    refute r.ok
    assert r.bounded["transactions"].raw_rows == 1
    refute r.fingerprint == before.fingerprint
    assert r.sample.bad == [{tx_2.txid, :no_raw_in_row}]
    assert r.sample.ok == 1
    assert Enum.any?(r.failures, &(&1 =~ "1 sampled tx(s) failed: 1 :no_raw_in_row"))
  end

  test "a row whose bytes moved to the store (raw_in_db false) is read from the store, counted apart",
       %{tx_2: tx_2} do
    :ok = TxStore.put(tx_2.txid, Base.decode16!(@raw_2, case: :lower))

    Repo.update_all(from(t in Bitblocks.Chain.Transaction, where: t.txid == ^tx_2.txid),
      set: [raw: nil, raw_in_db: false]
    )

    r = RestoreCheck.run(sample: 10)

    assert r.ok, inspect(r.failures)
    assert r.sample == %{checked: 2, ok: 1, from_store: 1, bad: []}
  end

  defp set_raw(txid, raw) do
    Repo.update_all(from(t in Bitblocks.Chain.Transaction, where: t.txid == ^txid),
      set: [raw: raw]
    )
  end

  test "through: a lower height counts and samples only up to it, and changes the fingerprint" do
    whole = RestoreCheck.run(sample: 0)
    r = RestoreCheck.run(through: 1, sample: 10)

    assert r.ok
    assert r.bounded["transactions"].total == 1
    assert r.sample.checked == 1
    assert r.headers.checked == 2
    refute r.fingerprint == whole.fingerprint
  end

  test "a row whose bytes don't hash to its txid, and a tampered header, fail the check", %{
    tx_2: tx_2
  } do
    set_raw(tx_2.txid, @raw_1)

    Repo.update_all(from(b in Block, where: b.height == 1), set: [nonce: 1])

    r = RestoreCheck.run(sample: 10)

    refute r.ok
    assert r.sample.bad == [{tx_2.txid, :bytes_do_not_hash_to_txid}]
    assert r.headers.bad == [1]
    assert "1 sampled tx(s) failed: 1 :bytes_do_not_hash_to_txid" in r.failures
    assert "1 header(s) fail verification" in r.failures
  end

  test "comparing above complete_through fails rather than reading a partial chain" do
    r = RestoreCheck.run(through: 9, sample: 0)

    refute r.ok
    assert Enum.any?(r.failures, &(&1 =~ "above this database's complete_through 2"))
  end

  test "it runs read-only: a write inside its transaction is refused" do
    error =
      assert_raise Postgrex.Error, fn ->
        RestoreCheck.run(sample: 0, probe: fn -> Repo.query!("UPDATE blocks SET nonce = 1") end)
      end

    assert error.postgres.code == :read_only_sql_transaction
  end

  test "statement_timeout_ms caps each statement" do
    error =
      assert_raise Postgrex.Error, fn ->
        RestoreCheck.run(
          statement_timeout_ms: 10,
          probe: fn -> Repo.query!("SELECT pg_sleep(1)") end
        )
      end

    assert error.postgres.code == :query_canceled
    assert RestoreCheck.run(sample: 0, statement_timeout_ms: 60_000).ok
  end

  test "READ ONLY comes first, and no statement writes" do
    test_pid = self()
    handler = "restore-check-queries-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:bitblocks, :repo, :query],
      fn _event, _measurements, meta, _ -> send(test_pid, {:query, meta.query}) end,
      nil
    )

    try do
      RestoreCheck.run(sample: 10)
    after
      :telemetry.detach(handler)
    end

    queries = collect_queries([])

    statements =
      Enum.reject(queries, &(&1 in ["begin", "commit"] or &1 =~ ~r/^SAVEPOINT|^RELEASE/))

    assert hd(statements) == "SET TRANSACTION READ ONLY"
    assert length(statements) > 5
    refute Enum.any?(statements, &(&1 =~ ~r/\b(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP)\b/i))
  end

  defp collect_queries(acc) do
    receive do
      {:query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "Release.restore_check/1 prints the numbers to compare and OK" do
    {r, io} = with_io(fn -> Release.restore_check(sample: 10) end)

    assert r.ok
    assert io =~ "complete_through  2"
    assert io =~ "fingerprint       #{r.fingerprint}"
    assert io =~ "full fingerprint  #{r.full_fingerprint}"
    assert io =~ ~r/transactions\s+2\n/
    assert io =~ ~r/transactions with raw\s+2\n/
    assert io =~ ~r/transactions raw bytes\s+256\n/
    assert io =~ "headers 0..2: 3 verified, 3 canonical of 3, 0 missing"
    assert io =~ "sample: 2 of 2 rows' own raw hash to their txid"
    assert io =~ ~r/\nOK\n/
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
