defmodule Bitblocks.Chain.TxPipeline.CFilesBackfillTest do
  # Release.backfill_c_files/3 (https://github.com/afomi/bitblocks/issues/147):
  # dry run first, writes only the file rows missing at the version, and
  # never writes to transactions.
  use Bitblocks.DataCase, async: true

  import Bitblocks.BcatFixtures
  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures, only: [publish: 1]

  alias Bitblocks.CFiles
  alias Bitblocks.CFiles.{CFile, Miss}
  alias Bitblocks.Chain.Transaction
  alias Bitblocks.Chain.TxPipeline.CFilesBackfill

  @txid "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
  @hex "test/fixtures/bob/#{@txid}.hex" |> File.read!() |> String.trim()

  setup do
    b = transaction_fixture(%{txid: @txid, raw: @hex, protocols: ["B://"], block_height: 500})
    # Tagged, but with no B:// file of its own.
    transaction_fixture(%{raw: "00", protocols: ["B://"], block_height: 600})
    # Not tagged: never read.
    transaction_fixture(%{raw: @hex, protocols: ["MAP"], block_height: 500})
    %{b: b}
  end

  test "a dry run counts what it would write and writes nothing" do
    before = Repo.all(from(t in Transaction, select: t.updated_at, order_by: t.id))
    report = CFilesBackfill.run(0, 1_000, pause_ms: 0)

    assert report.outcome == "ok"
    refute report.applied
    assert report.rows_examined == 2
    assert report.rows_changed == 1
    assert report.rows_below_version == 1
    assert %{files_found: 1, no_file: 1, no_raw: 0, bcat_heads: 0} = report.details
    assert Repo.aggregate(CFile, :count) == 0
    assert Repo.all(from(t in Transaction, select: t.updated_at, order_by: t.id)) == before
  end

  test "an apply writes the missing rows once; a rerun writes nothing" do
    report = CFilesBackfill.run(0, 1_000, apply: true, pause_ms: 0)
    assert report.rows_changed == 1
    assert report.rows_below_version == 0
    assert [%CFile{txid: @txid, block_height: 500, size: 8}] = Repo.all(CFile)

    again = CFilesBackfill.run(0, 1_000, apply: true, pause_ms: 0)
    assert again.rows_changed == 0
    assert CFilesBackfill.run(0, 1_000, pause_ms: 0).rows_below_version == 0
  end

  test "keeps to its range, and a run from block 0 sets how far the index reaches" do
    assert CFilesBackfill.run(501, 1_000, apply: true, pause_ms: 0).rows_changed == 0
    assert CFiles.indexed_through(1_000) == nil

    CFilesBackfill.run(0, 500, apply: true, pause_ms: 0)
    assert Repo.aggregate(CFile, :count) == 1
    assert CFiles.indexed_through(1_000) == 1_000
    assert CFiles.indexed_through(700) == 700
  end

  test "pages through tagged txs, small pages included" do
    report = CFilesBackfill.run(0, 1_000, apply: true, pause_ms: 0, tx_batch: 1)
    assert report.rows_examined == 2
    assert report.rows_changed == 1
  end

  test "a page reads the B:// partial index, never the primary key or a block walk" do
    for _ <- 1..20, do: transaction_fixture(%{protocols: ["MAP"], block_height: 500})

    query = CFilesBackfill.page_query(0, %{from_height: 0, to_height: 1_000, tx_batch: 200})
    {sql, params} = Repo.to_sql(:all, query)

    Repo.query!("SET LOCAL enable_seqscan = off")
    %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
    plan = Enum.map_join(rows, "\n", &hd/1)

    assert plan =~ "transactions_b_protocol_id_index", plan
    refute plan =~ "transactions_pkey", plan
  end

  test "a B:// row an earlier version wrote, unchanged, is not written again" do
    CFilesBackfill.run(0, 1_000, apply: true, pause_ms: 0)
    Repo.update_all(from(c in CFile), set: [version: 1])

    assert CFilesBackfill.run(0, 1_000, pause_ms: 0).rows_below_version == 0
    assert CFilesBackfill.run(0, 1_000, apply: true, pause_ms: 0).rows_changed == 0
    assert [%CFile{version: 1}] = Repo.all(CFile)
  end

  test "only an applied run at the current version sets how far the index reaches" do
    Repo.insert!(%Bitblocks.Derivations.Run{
      derivation: "c_files",
      version: 1,
      from_height: 0,
      to_height: 1_000,
      applied: true,
      outcome: "ok",
      started_at: DateTime.utc_now()
    })

    assert CFiles.indexed_through(1_000) == nil
  end

  describe "BCat heads" do
    defp bcat_head(height, parts, opts \\ []) do
      block = block_fixture(height: height)
      chunks = Enum.map(parts, &chunk/1)
      {txid, hex} = head(chunks)

      transaction_fixture(%{
        txid: txid,
        raw: hex,
        protocols: ["BCat"],
        block_hash: block.hash,
        block_height: height
      })

      unless opts[:missing], do: Enum.each(chunks, &publish/1)
      txid
    end

    test "a dry run counts the heads to assemble, and fetches nothing" do
      bcat_head(700, ["a", "b"])
      Process.put(:woc_txs_error, :should_not_be_asked)

      report = CFilesBackfill.run(0, 1_000, pause_ms: 0)

      assert report.outcome == "ok"
      assert report.blocks_examined == 1
      assert report.details.bcat_heads == 1
      # The B:// file, and the head to assemble.
      assert report.rows_below_version == 2
      assert Repo.aggregate(CFile, :count) == 0
    end

    test "an apply assembles and indexes each head once; a rerun assembles nothing" do
      txid = bcat_head(700, ["hello ", "world"])

      report = CFilesBackfill.run(0, 1_000, apply: true, pause_ms: 0)
      assert report.details.bcat_indexed == 1
      assert report.rows_changed == 2

      assert [%CFile{kind: "bcat", chunks: 2, size: 11, block_height: 700}] =
               CFiles.locations(:crypto.hash(:sha256, "hello world"))

      assert CFiles.bcat_indexed?(txid)

      # Nothing more to fetch: WhatsOnChain would refuse now.
      Process.put(:woc_txs_error, :should_not_be_asked)
      again = CFilesBackfill.run(0, 1_000, apply: true, pause_ms: 0)
      assert again.rows_changed == 0
      assert again.details.bcat_already == 1
      assert CFilesBackfill.run(0, 1_000, pause_ms: 0).rows_below_version == 0
    end

    test "a head that doesn't assemble stays unindexed with its reason, and a dry run says so" do
      txid = bcat_head(700, ["gone"], missing: true)

      report = CFilesBackfill.run(0, 1_000, apply: true, pause_ms: 0)
      assert report.details.bcat_unindexed == 1
      assert report.details.bcat_reasons == %{missing_chunks: 1}
      assert [%Miss{txid: ^txid, reason: "missing_chunks"}] = Repo.all(Miss)

      # Tried at this version: reported as unindexed, not as work left to do.
      dry = CFilesBackfill.run(0, 1_000, pause_ms: 0)
      assert dry.rows_below_version == 0
      assert dry.details.bcat_unindexed == 1
      assert dry.details.bcat_reasons == %{missing_chunks: 1}
    end

    test "keeps to its range, and walks blocks in small batches too" do
      bcat_head(700, ["in"])
      bcat_head(2_000, ["out"])

      report =
        CFilesBackfill.run(0, 1_000, apply: true, pause_ms: 0, block_batch: 1, tx_batch: 1)

      assert report.details.bcat_heads == 1
      assert [%CFile{block_height: 700}] = Repo.all(from(c in CFile, where: c.kind == "bcat"))
    end

    test "a page reads the block_hash index, never the primary key" do
      block = block_fixture(height: 700)
      for _ <- 1..20, do: transaction_fixture(%{block_hash: block.hash, protocols: ["MAP"]})

      query = CFilesBackfill.bcat_page_query(block, 0, %{tx_batch: 200})
      {sql, params} = Repo.to_sql(:all, query)

      Repo.query!("SET LOCAL enable_seqscan = off")
      %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
      plan = Enum.map_join(rows, "\n", &hd/1)

      refute plan =~ "transactions_pkey", plan
    end
  end
end
