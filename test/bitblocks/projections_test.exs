defmodule Bitblocks.ProjectionsTest do
  @moduledoc """
  #29 step 1: a projection is a tenant's filter over the ingest-time tag
  columns on `transactions`. See docs/MANAGED_SERVICES.md.
  """
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Projections
  alias Bitblocks.Projections.Projection

  @donation "1DonationAddressXXXXXXXXXXXXXXXXX"
  @qart_key "1QartSigningKeyXXXXXXXXXXXXXXXXXX"

  describe "create/1" do
    test "stores a filter over two tag columns and round-trips it" do
      filter = %{"protocols" => ["MAP"], "aip_signers" => [@qart_key]}

      assert {:ok, %Projection{} = p} =
               Projections.create(%{tenant: "qart", name: "receipts", filter: filter})

      assert Projections.get!(p.id).filter == filter
      assert p.status == "backfilling"
    end

    test "rejects unknown columns, empty value lists and non-string values" do
      for filter <- [
            %{"raw" => ["x"]},
            %{"output_addresses" => []},
            %{"output_addresses" => [1]},
            %{"output_addresses" => "1abc"},
            %{}
          ] do
        assert {:error, changeset} =
                 Projections.create(%{tenant: "t", name: "n", filter: filter})

        assert %{filter: [_ | _]} = errors_on(changeset), inspect(filter)
      end
    end

    test "the definition hash ignores key and value order" do
      {:ok, a} =
        Projections.create(%{
          tenant: "a",
          name: "a",
          filter: %{"protocols" => ["MAP", "AIP"], "aip_signers" => [@qart_key]}
        })

      {:ok, b} =
        Projections.create(%{
          tenant: "b",
          name: "b",
          filter: %{"aip_signers" => [@qart_key], "protocols" => ["AIP", "MAP"]}
        })

      assert a.definition_hash == b.definition_hash
      assert a.definition_hash =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  describe "query/1" do
    test "matches txs carrying every listed tag, across columns (AND)" do
      both = transaction_fixture(%{protocols: ["MAP", "AIP"], aip_signers: [@qart_key]})
      _spoof = transaction_fixture(%{protocols: ["MAP"], aip_signers: []})
      _other = transaction_fixture(%{output_addresses: [@donation]})

      {:ok, p} =
        Projections.create(%{
          tenant: "qart",
          name: "receipts",
          filter: %{"protocols" => ["MAP"], "aip_signers" => [@qart_key]}
        })

      assert [tx] = Repo.all(Projections.query(p))
      assert tx.id == both.id
    end

    test "compiles to containment the GIN indexes can serve, not a seq scan" do
      {:ok, p} =
        Projections.create(%{
          tenant: "visible-dao",
          name: "donations",
          filter: %{"output_addresses" => [@donation], "protocols" => ["MAP"]}
        })

      # The test table is tiny, so force the planner off seq scans: if the
      # predicate can't use an index (e.g. `x = ANY(col)`), it still seq scans.
      Repo.query!("SET LOCAL enable_seqscan = off")
      {sql, params} = Repo.to_sql(:all, Projections.query(p))
      plan = Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)

      refute plan =~ "Seq Scan on transactions", plan
      assert plan =~ "transactions_output_addresses_index", plan
    end
  end

  describe "hydrate/2" do
    setup do
      {:ok, p} =
        Projections.create(%{
          tenant: "visible-dao",
          name: "donations",
          filter: %{"output_addresses" => [@donation]}
        })

      # Deliberately out of order, two per height, so ties break on txid.
      txs =
        for {height, n} <- [{30, 1}, {10, 2}, {20, 3}, {10, 4}, {30, 5}] do
          transaction_fixture(%{
            block_height: height,
            txid: String.duplicate("#{n}", 64),
            output_addresses: [@donation]
          })
        end

      _unrelated = transaction_fixture(%{block_height: 10, output_addresses: ["1other"]})
      _mempool = transaction_fixture(%{block_height: nil, output_addresses: [@donation]})

      %{projection: p, txs: txs}
    end

    test "paging the whole set equals the unpaged, ordered set", %{projection: p, txs: txs} do
      expected = txs |> Enum.sort_by(&{&1.block_height, &1.txid}) |> Enum.map(& &1.txid)

      assert page_through(p, snapshot_height: 30, limit: 2) == expected
      assert {:ok, %{txs: all, next_cursor: nil}} = Projections.hydrate(p, snapshot_height: 30)
      assert Enum.map(all, & &1.txid) == expected
    end

    test "excludes unconfirmed txs and anything above the snapshot", %{projection: p} do
      {:ok, page} = Projections.hydrate(p, snapshot_height: 20)

      assert Enum.map(page.txs, & &1.block_height) == [10, 10, 20]
      assert page.snapshot_height == 20
    end

    test "a new block doesn't shift pages already handed out", %{projection: p} do
      {:ok, first} = Projections.hydrate(p, snapshot_height: 30, limit: 2)

      # Confirms between page 1 and page 2, above the snapshot.
      transaction_fixture(%{
        block_height: 31,
        txid: String.duplicate("0", 64),
        output_addresses: [@donation]
      })

      {:ok, second} = Projections.hydrate(p, cursor: first.next_cursor, limit: 2)

      assert second.snapshot_height == 30
      refute Enum.any?(second.txs, &(&1.block_height == 31))
      assert Enum.map(second.txs, & &1.block_height) == [20, 30]
    end

    test "the snapshot defaults to the highest stored block", %{projection: p} do
      block_fixture(%{height: 20})

      assert {:ok, %{snapshot_height: 20, txs: txs}} = Projections.hydrate(p)
      assert length(txs) == 3
    end

    test "rejects a malformed cursor or one from another projection", %{projection: p} do
      {:ok, other} =
        Projections.create(%{
          tenant: "qart",
          name: "x",
          filter: %{"output_addresses" => [@donation]}
        })

      {:ok, %{next_cursor: cursor}} = Projections.hydrate(other, snapshot_height: 30, limit: 1)

      assert {:error, :invalid_cursor} = Projections.hydrate(p, cursor: "not-a-cursor")
      assert {:error, :invalid_cursor} = Projections.hydrate(p, cursor: cursor)
    end
  end

  describe "Release CLI" do
    test "create_projection/1 returns the projection or readable errors" do
      assert {:ok, %Projection{id: id}} =
               Bitblocks.Release.create_projection(%{
                 tenant: "t",
                 name: "n",
                 filter: %{"aip_signers" => [@qart_key]}
               })

      assert {:error, %{filter: [_]}} =
               Bitblocks.Release.create_projection(%{
                 tenant: "t",
                 name: "m",
                 filter: %{"raw" => ["x"]}
               })

      assert {id, "t", "n", "backfilling"} in Bitblocks.Release.list_projections()
    end
  end

  defp page_through(p, opts, acc \\ []) do
    {:ok, page} = Projections.hydrate(p, opts)
    acc = acc ++ Enum.map(page.txs, & &1.txid)

    case page.next_cursor do
      nil -> acc
      cursor -> page_through(p, Keyword.put(opts, :cursor, cursor), acc)
    end
  end
end
