defmodule Bitblocks.Chain.BlockTxidsBoundedTest do
  # A block page for a large block far above the sync ran for minutes and
  # returned 500: the stored-txs page ordered by the bare `id`, so Postgres
  # could walk `transactions_pkey` filtering on `block_hash`, and for a block
  # with no stored rows that reads the whole table. Every read is bounded now.
  #
  # Not async: the plan test changes a column's statistics target in the
  # sandbox transaction, which locks `transactions` until the test ends.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{BlockTxids, Transaction}
  alias Bitblocks.Repo

  defp capture_transactions_queries(fun) do
    test_pid = self()
    handler = "block-txids-bounded-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:bitblocks, :repo, :query],
      fn _event, _measurements, meta, _ ->
        if meta.query =~ ~s("transactions"), do: send(test_pid, {:tx_query, meta.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, collect([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect(acc) do
    receive do
      {:tx_query, sql} -> collect([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a far-tip block with millions of txs and none stored costs one capped count" do
    block =
      block_fixture(%{
        height: 957_599,
        hash: "far957599",
        sync_state: "header_only",
        num_tx: 4_000_000,
        tx: []
      })

    {{:ok, loaded}, queries} =
      capture_transactions_queries(fn -> BlockTxids.load(block, 0, 1, 50) end)

    assert loaded.total == 0
    assert loaded.txids == []
    assert [count_sql] = queries
    assert count_sql =~ "LIMIT"
  end

  test "a completed block takes its total from num_tx and pages a big block by txid" do
    block =
      block_fixture(%{
        height: 635_141,
        hash: "big635141",
        sync_state: "completed",
        num_tx: 3_000_000,
        tx: []
      })

    for txid <- ~w(c_b c_a c_c),
        do: transaction_fixture(%{txid: txid, block_hash: "big635141", block_height: 635_141})

    {{:ok, loaded}, queries} =
      capture_transactions_queries(fn -> BlockTxids.load(block, 0, 1, 2) end)

    assert loaded.total == 3_000_000
    assert loaded.order == :txid
    assert loaded.txids == ["c_a", "c_b"]
    assert Map.keys(loaded.summaries) |> Enum.sort() == ["c_a", "c_b"]
    refute Enum.any?(queries, &(&1 =~ "count("))
    assert Enum.any?(queries, &(&1 =~ ~s(ORDER BY t0."block_height", t0."txid")))
  end

  test "a block not yet complete counts at most 100,000 stored txs" do
    block = block_fixture(%{hash: "partial1", sync_state: "txs_syncing", num_tx: 2, tx: []})

    for txid <- ~w(p_a p_b),
        do: transaction_fixture(%{txid: txid, block_hash: "partial1", block_height: block.height})

    assert {:ok, %{total: 2, total_capped: false, order: :block, txids: ["p_a", "p_b"]}} =
             BlockTxids.load(block, 0, 1, 50)

    assert BlockTxids.count(block, 1) == 1
  end

  test "the block-order page never plans on the primary key, where the old query did" do
    # Ten blocks of 3,000 stored txs each, with statistics that keep no
    # common values: Postgres expects thousands of rows for any hash, so a
    # bare ORDER BY id LIMIT 50 looks cheapest as a walk of the primary key.
    now = NaiveDateTime.utc_now(:second)

    for chunk <- Enum.chunk_every(1..30_000, 5_000) do
      rows =
        for n <- chunk do
          %{
            txid: "plan#{n}",
            block_hash: "planblk#{rem(n, 10)}",
            block_height: 800_000 + rem(n, 10),
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Transaction, rows)
    end

    Repo.query!("ALTER TABLE transactions ALTER COLUMN block_hash SET STATISTICS 1")
    Repo.query!("ANALYZE transactions")

    absent = %Bitblocks.Chain.Block{hash: "absent-hash", height: 957_599}

    plan = fn query ->
      {sql, params} = Repo.to_sql(:all, query)
      Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)
    end

    old =
      from(t in Transaction,
        where: t.block_hash == ^absent.hash,
        order_by: [asc: t.id],
        offset: 0,
        limit: 50,
        select: t.txid
      )

    assert plan.(old) =~ "transactions_pkey"
    refute plan.(BlockTxids.stored_page_query(absent, :block, 1, 50)) =~ "transactions_pkey"
    refute plan.(BlockTxids.stored_page_query(absent, :txid, 1, 50)) =~ "transactions_pkey"
  end

  describe "Repo.with_statement_timeout/2" do
    test "a statement past the timeout comes back as a timeout, in about that long" do
      {micros, result} =
        :timer.tc(fn ->
          Repo.with_statement_timeout(100, fn -> Repo.query!("SELECT pg_sleep(5)") end)
        end)

      assert result == {:error, :timeout}
      assert micros < 2_000_000
    end

    test "leaves the connection's statement timeout as it found it" do
      [[before]] = Repo.query!("SHOW statement_timeout").rows
      assert {:ok, 1} = Repo.with_statement_timeout(250, fn -> 1 end)
      assert Repo.query!("SHOW statement_timeout").rows == [[before]]
    end
  end
end
