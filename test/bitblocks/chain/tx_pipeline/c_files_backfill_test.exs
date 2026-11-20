defmodule Bitblocks.Chain.TxPipeline.CFilesBackfillTest do
  # Release.backfill_c_files/3 (https://github.com/afomi/bitblocks/issues/147):
  # dry run first, writes only the file rows missing at the version, and
  # never writes to transactions.
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.CFiles
  alias Bitblocks.CFiles.CFile
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
    assert report.details == %{files_found: 1, no_file: 1, no_raw: 0}
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
end
