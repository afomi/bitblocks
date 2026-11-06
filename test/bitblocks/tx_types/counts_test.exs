defmodule Bitblocks.TxTypes.CountsTest do
  # /types counts (#49): summed from blocks.type_counts over the blocks
  # verified complete and typed, cached, never a COUNT on transactions.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.TxPipeline
  alias Bitblocks.TxTypes.Counts

  defp typed_block(height, counts, opts \\ []) do
    block =
      block_fixture(%{height: height, sync_state: Keyword.get(opts, :state, "completed")})

    Repo.update_all(
      from(b in Bitblocks.Chain.Block, where: b.id == ^block.id),
      set: [
        type_counts: counts,
        type_counts_version: Keyword.get(opts, :version, TxPipeline.version(:type_counts))
      ]
    )

    block
  end

  test "sums each type over the blocks complete and typed, with the first height seen" do
    typed_block(0, %{"custom" => 1})
    typed_block(1, %{"custom" => 1, "p2pkh" => 2})
    typed_block(2, %{"p2pkh" => 3, "op-return" => 1})

    summary = Counts.compute()

    assert summary.status == :ok
    assert summary.through_height == 2
    assert summary.complete_through == 2
    assert summary.version == TxPipeline.version(:type_counts)

    assert summary.types["custom"] == %{txs: 2, first_height: 0}
    assert summary.types["p2pkh"] == %{txs: 5, first_height: 1}
    assert summary.types["op-return"] == %{txs: 1, first_height: 2}
    refute Map.has_key?(summary.types, "bsv-21")
  end

  describe "adoption (#51)" do
    test "first time and txid, and txs per 10,000 blocks, over the typed range" do
      first = typed_block(0, %{"p2pkh" => 1})

      Repo.update_all(from(b in Bitblocks.Chain.Block, where: b.id == ^first.id),
        set: [time: 111]
      )

      typed_block(1, %{"p2pkh" => 2})

      transaction_fixture(%{txid: "b_later", block_hash: first.hash, tx_types: ["p2pkh"]})
      transaction_fixture(%{txid: "a_other", block_hash: first.hash, tx_types: ["custom"]})

      summary = Counts.compute()

      assert %{
               first_txid: "b_later",
               first_time: 111,
               per_10000_blocks: [%{from_height: 0, txs: 3}]
             } = Counts.adoption(summary, "p2pkh")
    end

    test "buckets split on 10,000 blocks; only the typed range counts" do
      blocks =
        for height <- 0..10_001 do
          %{
            height: height,
            hash: "b#{height}",
            sync_state: "completed",
            type_counts: %{"custom" => 1},
            type_counts_version: TxPipeline.version(:type_counts),
            inserted_at: ~N[2026-11-05 00:00:00],
            updated_at: ~N[2026-11-05 00:00:00],
            tx: []
          }
        end

      blocks
      |> Enum.chunk_every(1_000)
      |> Enum.each(&Repo.insert_all(Bitblocks.Chain.Block, &1))

      assert %{per_10000_blocks: [%{from_height: 0, txs: 10_000}, %{from_height: 10_000, txs: 2}]} =
               Counts.adoption(Counts.compute(), "custom")
    end

    test "a type with no first tx stored says nil, not a guess" do
      typed_block(0, %{"custom" => 1})

      assert %{first_txid: nil} = Counts.adoption(Counts.compute(), "custom")
    end

    test "no adoption without counts" do
      assert Counts.adoption(%{status: :pending}, "custom") == nil
    end
  end

  test "stops at the first block not typed at the current version, and says so" do
    typed_block(0, %{"custom" => 1})
    typed_block(1, %{"p2pkh" => 1}, version: nil)
    typed_block(2, %{"p2pkh" => 7})

    summary = Counts.compute()

    assert summary.complete_through == 2
    assert summary.through_height == 0
    assert summary.types == %{"custom" => %{txs: 1, first_height: 0}}
  end

  test "counts nothing past the blocks verified complete" do
    typed_block(0, %{"custom" => 1})
    typed_block(1, %{"p2pkh" => 1}, state: "header_only")
    typed_block(2, %{"p2pkh" => 7})

    summary = Counts.compute()

    assert summary.complete_through == 0
    assert summary.through_height == 0
    assert summary.tip == 2
    assert Map.keys(summary.types) == ["custom"]
  end

  test "with nothing typed, the range is empty" do
    block_fixture(%{height: 0, sync_state: "completed"})

    summary = Counts.compute()
    assert summary.through_height == -1
    assert summary.types == %{}
  end

  test "get/0 serves what refresh/0 stored, without a query" do
    typed_block(0, %{"custom" => 4})

    assert %{status: :ok, types: %{"custom" => %{txs: 4}}} = Counts.refresh()

    # A change after the refresh is not seen until the next one.
    typed_block(1, %{"custom" => 1})
    assert %{through_height: 0, types: %{"custom" => %{txs: 4}}} = Counts.get()
  end

  test "count/2 reads one type from a summary, 0 when unseen" do
    summary = %{status: :ok, types: %{"p2pkh" => %{txs: 3, first_height: 9}}}
    assert Counts.count(summary, "p2pkh") == %{txs: 3, first_height: 9}
    assert Counts.count(summary, "bsv-21") == %{txs: 0, first_height: nil}
    assert Counts.count(%{status: :pending}, "p2pkh") == nil
  end
end
