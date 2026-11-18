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
    assert r.bounded["transactions"] == %{total: 2, buckets: [{0, 2}]}
    assert r.unbounded["users"] == 0
    assert r.headers == %{checked: 3, verified: 3, canonical: 3, missing: 0, bad: []}
    assert r.sample == %{checked: 2, ok: 2, bad: []}
    assert r.database.name =~ "bitblocks_test"
  end

  test "the chain digest and fingerprint are the hashes of their stated text" do
    r = RestoreCheck.run(sample: 0)

    chain_text =
      for h <- [0, 1, 2], into: "", do: "#{h}:#{RealHeaders.fields(h).hash}\n"

    assert r.chain.digest == sha256(chain_text)
    assert RestoreCheck.fingerprint_text(2, r.chain, r.bounded) =~ "transactions=2\n"
    assert r.fingerprint == sha256(RestoreCheck.fingerprint_text(2, r.chain, r.bounded))
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
    Repo.update_all(from(t in Bitblocks.Chain.Transaction, where: t.txid == ^tx_2.txid),
      set: [raw: @raw_1]
    )

    Repo.update_all(from(b in Block, where: b.height == 1), set: [nonce: 1])

    r = RestoreCheck.run(sample: 10)

    refute r.ok
    assert r.sample.bad == [{tx_2.txid, :bytes_do_not_hash_to_txid}]
    assert r.headers.bad == [1]
    assert "1 sampled tx(s) don't hash to their txid" in r.failures
    assert "1 header(s) fail verification" in r.failures
  end

  test "comparing above complete_through fails rather than reading a partial chain" do
    r = RestoreCheck.run(through: 9, sample: 0)

    refute r.ok
    assert Enum.any?(r.failures, &(&1 =~ "above this database's complete_through 2"))
  end

  test "it runs read-only: READ ONLY comes first, and no statement writes" do
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
    assert io =~ ~r/transactions\s+2\n/
    assert io =~ "headers 0..2: 3 verified, 3 canonical of 3, 0 missing"
    assert io =~ "sample: 2 of 2 txs hash to their txid"
    assert io =~ ~r/\nOK\n/
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
