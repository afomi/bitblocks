defmodule Bitblocks.CFilesTest do
  # The C:// index (https://github.com/afomi/bitblocks/issues/147): a B://
  # file's sha256 maps to the outputs that carry it.
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.CFiles
  alias Bitblocks.CFiles.CFile
  alias Bitblocks.Chain.TxPipeline
  alias Bitblocks.Derivations.Run

  # A real mainnet B:// + MAP tx (Twetch, 2019); see test/bitblocks/bob_test.exs.
  @txid "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
  @hex "test/fixtures/bob/#{@txid}.hex" |> File.read!() |> String.trim()
  @sha256 :crypto.hash(:sha256, "HAHAHAHA")

  defp stored(attrs \\ %{}) do
    block = block_fixture(height: 594_000)

    transaction_fixture(
      Map.merge(
        %{
          txid: @txid,
          raw: @hex,
          protocols: ["B://", "MAP"],
          block_hash: block.hash,
          block_height: block.height
        },
        attrs
      )
    )
    |> then(&{&1, block})
  end

  test "parse_address takes 64 hex characters in any case, and nothing else" do
    hex = Base.encode16(@sha256)
    assert CFiles.parse_address(hex) == {:ok, @sha256}
    assert CFiles.parse_address(String.downcase(hex)) == {:ok, @sha256}
    assert CFiles.parse_address("abc") == :error
    assert CFiles.parse_address(String.duplicate("g", 64)) == :error
  end

  test "rows: one per B:// file, keyed by the sha256 of its bytes" do
    assert [row] = CFiles.rows(@txid, @hex, 594_000)

    assert %{
             sha256: @sha256,
             txid: @txid,
             block_height: 594_000,
             media_type: "text/plain",
             encoding: "text",
             filename: "twetch_twtext_1565131423556.txt",
             size: 8,
             kind: "b",
             chunks: nil,
             version: 2
           } = row

    assert is_integer(row.vout)
    assert CFiles.rows(@txid, "not hex", 1) == []
  end

  test "the step indexes a tx tagged B://, and costs nothing on any other" do
    {tx, block} = stored()
    assert CFiles.index(tx, block) == 1
    # Idempotent: the same output is rewritten, not added.
    assert CFiles.index(tx, block) == 1
    assert Repo.aggregate(CFile, :count) == 1

    untagged = %{tx | protocols: ["MAP"]}
    refute CFiles.candidate?(untagged)
    assert CFiles.index(untagged, block) == 0
  end

  test "index_c_files runs as a tx step" do
    {tx, block} = stored()

    assert {"index_c_files", :ok} in TxPipeline.run_tx(tx, block)
    assert [%CFile{txid: @txid}] = CFiles.locations(@sha256)
  end

  describe "resolve/1" do
    test "serves the oldest copy whose bytes hash to the address" do
      {tx, block} = stored()
      CFiles.index(tx, block)

      assert {:ok, %CFile{txid: @txid, media_type: "text/plain"}, "HAHAHAHA"} =
               CFiles.resolve(@sha256)
    end

    test "an address no row holds is not indexed" do
      assert CFiles.resolve(:crypto.hash(:sha256, "nope")) == {:error, :not_indexed}
    end

    test "a row whose bytes don't hash to its address is never served" do
      {tx, block} = stored()
      [row] = CFiles.rows(tx.txid, tx.raw, block.height)
      wrong = :crypto.hash(:sha256, "something else")
      CFiles.write([%{row | sha256: wrong}])

      assert CFiles.resolve(wrong) == {:error, :mismatch}
    end

    test "a copy whose tx can't be fetched just now is unavailable, read from WhatsOnChain bytes only" do
      # A tx of its own, held nowhere: another test's copy of the Twetch tx
      # may sit in the shared tx store.
      b = "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
      body = "unavailable #{System.unique_integer([:positive])}"
      script = %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, b, body, "text/plain"]}

      {txid, hex} =
        Bitblocks.OrdinalFixtures.tx(
          [Bitblocks.OrdinalFixtures.funding_outpoint()],
          [%BSV.TxOut{satoshis: 0, script: script}]
        )

      Process.put(:woc_raw_tx_only, true)
      Process.put(:woc_txs_error, :timeout)
      [row] = CFiles.rows(txid, hex, 594_000)
      CFiles.write([row])

      assert CFiles.resolve(:crypto.hash(:sha256, body)) == {:error, :unavailable}
      assert [{:txs, [[^txid]]}] = Process.get(:woc_calls)
    end
  end

  test "a reorg's removed txs take their rows with them, and moved ones their height" do
    {tx, block} = stored()
    CFiles.index(tx, block)

    assert CFiles.moved([@txid], 594_001) == 1
    assert [%CFile{block_height: 594_001}] = CFiles.locations(@sha256)

    assert CFiles.delete_txids([@txid]) == 1
    assert CFiles.locations(@sha256) == []
  end

  describe "indexed_through/1" do
    defp run(from, to, attrs \\ []) do
      Repo.insert!(
        struct(
          %Run{
            derivation: "c_files",
            version: CFiles.version(),
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

    test "nil until applied runs cover the chain from block 0" do
      assert CFiles.indexed_through(100) == nil
      run(10, 100)
      assert CFiles.indexed_through(100) == nil
      run(0, 50, applied: false)
      assert CFiles.indexed_through(100) == nil
    end

    test "the end of the contiguous runs from block 0, capped at complete_through" do
      run(0, 40)
      run(41, 90)
      run(95, 200)
      assert CFiles.indexed_through(1_000) == 90
      assert CFiles.indexed_through(60) == 60
      assert CFiles.indexed_through(nil) == nil
    end
  end
end
