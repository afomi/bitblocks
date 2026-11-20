defmodule Bitblocks.CFilesBcatTest do
  # BCat files in the C:// index (https://github.com/afomi/bitblocks/issues/155):
  # a head's address is the sha256 of the assembled file, indexed only once
  # every chunk was found and checked against its txid; a head that doesn't
  # assemble stays unindexed, with its reason.
  use Bitblocks.DataCase, async: true
  use Oban.Testing, repo: Bitblocks.Repo

  import Bitblocks.BcatFixtures
  import Bitblocks.ChainFixtures
  import Bitblocks.OrdinalFixtures, only: [publish: 1]

  alias Bitblocks.CFiles
  alias Bitblocks.CFiles.{CFile, Miss}
  alias Bitblocks.Chain.TxPipeline
  alias Bitblocks.Workers.CFileBcatWorker

  defp store({txid, hex}, block) do
    transaction_fixture(%{
      txid: txid,
      raw: hex,
      protocols: ["BCat"],
      block_hash: block.hash,
      block_height: block.height
    })
  end

  defp stored_file(parts) do
    block = block_fixture(height: 600_000)
    chunks = Enum.map(parts, &chunk/1)
    {txid, _} = h = head(chunks)
    tx = store(h, block)
    # Chunks we don't hold come from WhatsOnChain, each checked against its txid.
    Enum.each(chunks, &publish/1)
    %{txid: txid, tx: tx, block: block, chunks: chunks}
  end

  test "the step enqueues the head's assembly, and assembles nothing inline" do
    %{txid: txid, tx: tx, block: block} = stored_file(["hello ", "world"])

    assert {"index_c_files", :ok} in TxPipeline.run_tx(tx, block)
    assert Repo.aggregate(CFile, :count) == 0

    assert_enqueued(
      worker: CFileBcatWorker,
      queue: :derived,
      args: %{"txid" => txid, "block_height" => 600_000}
    )

    # Unique on the head: a second run of the step adds no job.
    TxPipeline.run_tx(tx, block)
    assert length(all_enqueued(worker: CFileBcatWorker)) == 1
  end

  test "the job indexes the file by the sha256 of the whole, with its kind and chunks" do
    %{txid: txid} = stored_file(["hello ", "from ", "the chain"])

    assert :ok = perform_job(CFileBcatWorker, %{"txid" => txid, "block_height" => 1})

    sha = :crypto.hash(:sha256, "hello from the chain")

    assert [
             %CFile{
               kind: "bcat",
               txid: ^txid,
               vout: 0,
               block_height: 600_000,
               chunks: 3,
               size: 20,
               media_type: "text/plain",
               encoding: "utf-8",
               filename: "a file.txt",
               version: 2
             }
           ] = CFiles.locations(sha)

    assert {:ok, %CFile{kind: "bcat"}, "hello from the chain"} = CFiles.resolve(sha)

    # Done once: a rerun leaves it as it is.
    assert :ok = perform_job(CFileBcatWorker, %{"txid" => txid})
    assert Repo.aggregate(CFile, :count) == 1
  end

  test "a head with a chunk no source has stays unindexed, naming the chunk" do
    block = block_fixture(height: 600_001)
    [{gone, _} = missing, kept] = [chunk("gone"), chunk("kept")]
    {txid, _} = h = head([missing, kept])
    store(h, block)
    publish(kept)

    assert :ok = perform_job(CFileBcatWorker, %{"txid" => txid})

    assert Repo.aggregate(CFile, :count) == 0

    assert [%Miss{txid: ^txid, reason: "missing_chunks", missing_chunks: [^gone]}] =
             Repo.all(Miss)

    assert CFiles.coverage().bcat_unassembled == 1
    assert CFiles.misses_by_reason() == %{"missing_chunks" => 1}
  end

  test "a source that can't answer just now is retried, its miss recorded" do
    block = block_fixture(height: 600_002)
    {txid, _} = h = head([chunk("x")])
    store(h, block)
    Process.put(:woc_txs_error, :rate_limited)

    assert {:error, :unavailable} = perform_job(CFileBcatWorker, %{"txid" => txid})
    assert [%Miss{reason: "unavailable"}] = Repo.all(Miss)
  end

  test "an indexed file clears an earlier miss" do
    %{txid: txid} = stored_file(["later"])
    Process.put(:woc_txs_error, :rate_limited)
    perform_job(CFileBcatWorker, %{"txid" => txid})
    assert Repo.aggregate(Miss, :count) == 1

    Process.delete(:woc_txs_error)
    assert :ok = perform_job(CFileBcatWorker, %{"txid" => txid})
    assert Repo.aggregate(Miss, :count) == 0
    assert [%CFile{kind: "bcat"}] = Repo.all(CFile)
  end

  test "a head a reorg removed before its job ran is not indexed" do
    assert {:cancel, :head_not_stored} =
             perform_job(CFileBcatWorker, %{"txid" => String.duplicate("ab", 32)})
  end

  test "a reorg's removed heads take their rows and misses with them" do
    %{txid: txid} = stored_file(["bye"])
    perform_job(CFileBcatWorker, %{"txid" => txid})
    Repo.insert!(%Miss{txid: "other", reason: "too_large", version: 2})

    assert CFiles.delete_txids([txid, "other"]) == 1
    assert Repo.aggregate(CFile, :count) == 0
    assert Repo.aggregate(Miss, :count) == 0
  end

  test "a chunk changed after indexing is never served" do
    %{txid: txid} = stored_file(["original"])
    perform_job(CFileBcatWorker, %{"txid" => txid})
    sha = :crypto.hash(:sha256, "original")

    Repo.update_all(from(c in CFile), set: [sha256: :crypto.hash(:sha256, "other")])
    assert CFiles.resolve(:crypto.hash(:sha256, "other")) == {:error, :mismatch}
    assert CFiles.resolve(sha) == {:error, :not_indexed}
  end

  test "public names the kind, chunks and where the assembled file is served" do
    %{txid: txid} = stored_file(["ab", "cd"])
    perform_job(CFileBcatWorker, %{"txid" => txid})
    [row] = Repo.all(CFile)

    assert %{kind: "bcat", chunks: 2, size: 4, b_url: nil} = public = CFiles.public(row)
    assert public.bcat_url == "/content/bcat/#{txid}"
  end
end
