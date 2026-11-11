defmodule Bitblocks.TimelocksTest do
  # #76: the timelocks table, filled by the index_timelocks step and its
  # backfill, from real HodLocker txs (test/support/data/hodlocker_txs.json).
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.TxPipeline
  alias Bitblocks.Chain.TxPipeline.TimelocksBackfill
  alias Bitblocks.Timelocks
  alias Bitblocks.Timelocks.Lock

  @txs "test/support/data/hodlocker_txs.json"
       |> File.read!()
       |> Jason.decode!()
       |> Map.fetch!("txs")
       |> Map.new(&{&1["txid"], &1})

  @post "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
  @like "7f496c643364501f7b1c3f1593fd827b6e2af7207b3ead3ec04bb5666c16a88b"

  defp store(txid, attrs \\ %{}) do
    %{"raw" => raw, "height" => height} = @txs[txid]
    # The post and the like were mined in the same block.
    block = Bitblocks.Chain.get_block_at_height(height) || block_fixture(height: height)

    tx =
      transaction_fixture(
        Map.merge(
          %{txid: txid, raw: raw, block_hash: block.hash, block_height: height},
          attrs
        )
      )

    {tx, block}
  end

  test "the tx step writes a like's lock, naming the post it backs" do
    {tx, block} = store(@like, %{output_types: %{"unknown" => 1, "op_return" => 1}})

    assert {"index_timelocks", :ok} in TxPipeline.run_tx(tx, block)

    assert [
             %Lock{
               vout: 0,
               kind: "1sat_lock",
               satoshis: 2_100_000_000,
               unlock_height: 858_404,
               enforced: true,
               conditional: false,
               backs_txid: @post,
               app: "hodlocker",
               version: 1
             }
           ] = Timelocks.for_tx(@like)

    # Idempotent: a rerun rewrites the same row.
    TxPipeline.run_tx(tx, block)
    assert Repo.aggregate(Lock, :count) == 1
  end

  test "a tx whose outputs script analysis typed is never read" do
    {tx, block} = store(@like, %{output_types: %{"p2pkh" => 1}})

    refute Timelocks.candidate?(tx)
    assert Timelocks.index(tx, block) == 0
    assert Timelocks.for_tx(@like) == []
  end

  test "post_totals/1 sums what every indexed lock backs a post with" do
    {post, post_block} = store(@post)
    {like, like_block} = store(@like)
    Timelocks.index(post, post_block)
    Timelocks.index(like, like_block)

    assert %{
             post_txid: @post,
             satoshis: 2_100_000_001,
             locks: 2,
             txs: 2,
             likes: 1,
             first_unlock_height: 833_548,
             last_unlock_height: 858_404
           } = Timelocks.post_totals(@post)

    assert %{satoshis: 0, locks: 0, likes: 0} = Timelocks.post_totals(String.duplicate("0", 64))
  end

  test "backers/2 names who locked sats to a post, largest first (#75)" do
    {post, post_block} = store(@post)
    {like, like_block} = store(@like)
    Timelocks.index(post, post_block)
    Timelocks.index(like, like_block)

    assert [
             %{
               txid: @like,
               vout: 0,
               satoshis: 2_100_000_000,
               owner: "13PnV1oUFYAeMUzzvoKFWX9FpjnMxyUpM9",
               unlock_height: 858_404,
               block_height: 833_405
             },
             %{txid: @post, satoshis: 1, unlock_height: 833_548}
           ] = Timelocks.backers(@post)

    assert [%{txid: @like}] = Timelocks.backers(@post, 1)
    assert Timelocks.backers(String.duplicate("0", 64)) == []
  end

  describe "indexed_through/1 (#75)" do
    defp run!(from, to, attrs \\ %{}) do
      Repo.insert!(
        struct(
          %Bitblocks.Derivations.Run{
            derivation: "timelocks",
            version: Timelocks.version(),
            from_height: from,
            to_height: to,
            applied: true,
            outcome: "ok",
            started_at: DateTime.utc_now()
          },
          attrs
        )
      )
    end

    test "nil until an applied run covers block 0" do
      assert Timelocks.indexed_through(500) == nil

      run!(0, 100, %{applied: false})
      run!(10, 200)
      assert Timelocks.indexed_through(500) == nil
    end

    test "joins the runs that touch from block 0, up to the first gap" do
      run!(0, 100)
      run!(101, 300)
      run!(250, 400)
      run!(500, 900)
      # A run that stopped, or at an older version, covers nothing.
      run!(401, 499, %{outcome: "partial"})
      run!(401, 499, %{version: Timelocks.version() - 1})

      assert Timelocks.indexed_through(10_000) == 400
    end

    test "never reaches past complete_through" do
      run!(0, 1_000)

      assert Timelocks.indexed_through(321) == 321
      assert Timelocks.indexed_through(-1) == nil
      assert Timelocks.indexed_through(nil) == nil
    end
  end

  describe "the backfill" do
    test "dry run counts, apply inserts, a rerun writes nothing" do
      store(@like)
      height = @txs[@like]["height"]

      dry = TimelocksBackfill.run(height, height)

      assert %{
               derivation: "timelocks",
               applied: false,
               rows_examined: 1,
               rows_changed: 1,
               rows_below_version: 1,
               details: %{locks_found: 1, one_sat_lock: 1, enforced: 1, conditional: 0},
               outcome: "ok"
             } = dry

      assert Repo.aggregate(Lock, :count) == 0

      assert %{applied: true, rows_changed: 1, rows_below_version: 0} =
               TimelocksBackfill.run(height, height, apply: true)

      assert [%Lock{backs_txid: @post}] = Timelocks.for_tx(@like)

      assert %{rows_changed: 0} = TimelocksBackfill.run(height, height, apply: true)
    end

    test "reads only txs with an unknown output, and counts those with no bytes" do
      store(@like, %{output_types: %{"p2pkh" => 2}})
      block = block_fixture(height: 900_001)

      moved =
        transaction_fixture(
          txid: String.duplicate("ab", 32),
          raw: "00",
          block_hash: block.hash,
          block_height: 900_001
        )

      # Its bytes have moved to the tx store.
      Repo.update_all(
        from(t in Bitblocks.Chain.Transaction, where: t.id == ^moved.id),
        set: [raw: nil]
      )

      assert %{rows_examined: 0} =
               TimelocksBackfill.run(@txs[@like]["height"], @txs[@like]["height"])

      assert %{rows_examined: 1, details: %{no_raw: 1}} = TimelocksBackfill.run(900_001, 900_001)
    end

    test "records its run, and can be started as a chain" do
      assert %{derivation: "timelocks", run_id: id} = TimelocksBackfill.run(1, 2)
      assert is_integer(id)
      assert "timelocks" in Bitblocks.BackfillChains.derivations()
    end
  end
end
