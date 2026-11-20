defmodule BitblocksWeb.ContentControllerTest do
  @moduledoc """
  `/content/:outpoint` parses an inscription out of the raw tx on the fly
  (1Sat's `/content/{outpoint}` convention), so Tardinian SVGs that reference
  `/content/<origin>` render as served.
  """
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.OrdinalCollections

  setup do
    cid = "#{String.duplicate("c", 64)}_0"

    {txid, _hex} =
      built = tx([funding_outpoint()], [p2pkh(address(), 9_000), item(cid, "T1", address())])

    publish(built)
    %{txid: txid}
  end

  describe "GET /b/:txid" do
    @b "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"

    defp b_tx(pushes) do
      script = %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN | pushes]}
      tx([funding_outpoint()], [p2pkh(address(), 1_000), %BSV.TxOut{satoshis: 0, script: script}])
    end

    defp stored(built) do
      {txid, hex} = built
      block = Bitblocks.ChainFixtures.block_fixture()

      Bitblocks.ChainFixtures.transaction_fixture(%{
        txid: txid,
        raw: hex,
        block_hash: block.hash,
        block_height: block.height
      })

      txid
    end

    test "serves the file with its media type and untrusted-content headers" do
      txid = [@b, "<p>hello</p>", "text/html", "utf-8", "hi.html"] |> b_tx() |> stored()

      conn = build_conn() |> get("/b/#{txid}")

      assert conn.status == 200
      assert conn.resp_body == "<p>hello</p>"
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") |> hd() =~ "sandbox"
    end

    test "ignores the segments after a pipe" do
      txid = [@b, "body", "text/plain", "|", "MAP", "SET"] |> b_tx() |> stored()

      assert build_conn() |> get("/b/#{txid}") |> response(200) == "body"
    end

    test "a tx with no B:// file is a 404, and a bad txid a 400" do
      txid = ["not-b", "body"] |> b_tx() |> stored()

      assert %{"error" => "no B:// file" <> _} =
               build_conn() |> get("/b/#{txid}") |> json_response(404)

      assert build_conn() |> get("/b/nope") |> json_response(400)
    end

    test "an unknown media type is sent as bytes" do
      txid = [@b, "body", "not a type"] |> b_tx() |> stored()

      assert get_resp_header(build_conn() |> get("/b/#{txid}"), "content-type") |> hd() =~
               "application/octet-stream"
    end
  end

  test "serves an inscription body stored in the database, with untrusted-content headers", ctx do
    OrdinalCollections.import_txs([ctx.txid])

    conn = build_conn() |> get("/content/#{ctx.txid}_1")

    assert conn.status == 200
    assert conn.resp_body == "<svg/>"
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/svg+xml"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") |> hd() =~ "sandbox"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "a tx we don't hold is fetched, verified and kept in the blob store, not the database",
       ctx do
    conn = build_conn() |> get("/content/#{ctx.txid}.1")

    assert conn.status == 200
    assert conn.resp_body == "<svg/>"
    refute Bitblocks.Repo.get_by(Bitblocks.Chain.Transaction, txid: ctx.txid)
    assert {:ok, _bytes} = Bitblocks.TxStore.raw(ctx.txid)
  end

  test "an output without an inscription, or out of range, is a 404", ctx do
    OrdinalCollections.import_txs([ctx.txid])

    assert %{"error" => "no inscription" <> _} =
             build_conn() |> get("/content/#{ctx.txid}_0") |> json_response(404)

    assert build_conn() |> get("/content/#{ctx.txid}_7") |> json_response(404)
  end

  test "malformed outpoints are a 400; unknown txids a 404" do
    assert build_conn() |> get("/content/nope") |> json_response(400)
    assert build_conn() |> get("/content/#{String.duplicate("e", 64)}_0") |> json_response(404)
  end

  describe "GET /c/:sha256" do
    # A real mainnet B:// + MAP tx (Twetch, 2019); see test/bitblocks/bob_test.exs.
    @twetch "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
    @twetch_hex "test/fixtures/bob/#{@twetch}.hex" |> File.read!() |> String.trim()
    @sha "HAHAHAHA" |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    defp indexed do
      tx =
        Bitblocks.ChainFixtures.transaction_fixture(%{
          txid: @twetch,
          raw: @twetch_hex,
          protocols: ["B://", "MAP"],
          block_height: 594_000
        })

      Bitblocks.CFiles.index(tx, %Bitblocks.Chain.Block{height: 594_000})
    end

    test "serves the file by its sha256, hashed again, with untrusted-content headers" do
      indexed()

      conn = build_conn() |> get("/c/#{String.upcase(@sha)}")

      assert conn.status == 200
      assert conn.resp_body == "HAHAHAHA"
      assert :crypto.hash(:sha256, conn.resp_body) |> Base.encode16(case: :lower) == @sha
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") |> hd() =~ "sandbox"
      assert get_resp_header(conn, "cache-control") |> hd() =~ "immutable"
      assert get_resp_header(conn, "etag") == [~s("#{@sha}")]
    end

    test "an address the index doesn't hold says how far the index reaches" do
      unknown = String.duplicate("ab", 32)

      body = build_conn() |> get("/c/#{unknown}") |> json_response(404)

      assert %{
               "error" => "not_indexed",
               "sha256" => ^unknown,
               "message" => message,
               "meta" => %{"indexed_through_height" => nil, "source" => "c_files"} = meta
             } = body

      assert Map.has_key?(meta, "complete_through")
      assert message =~ "hasn't been backfilled from block 0"
    end

    test "a malformed address is a 400 naming the shape" do
      assert %{"error" => error} = build_conn() |> get("/c/nope") |> json_response(400)
      assert error =~ "64 hex characters"
    end

    test "bytes that don't hash to the address are never served" do
      indexed()
      wrong = :crypto.hash(:sha256, "other")

      Bitblocks.Repo.update_all(Bitblocks.CFiles.CFile, set: [sha256: wrong])

      conn = build_conn() |> get("/c/#{Base.encode16(wrong, case: :lower)}")
      assert %{"error" => error} = json_response(conn, 500)
      assert error =~ "nothing is served"
    end
  end

  describe "GET /c/:sha256 for a BCat file (https://github.com/afomi/bitblocks/issues/155)" do
    import Bitblocks.BcatFixtures

    defp bcat_indexed(parts) do
      chunks = Enum.map(parts, &chunk/1)
      {txid, hex} = head(chunks)

      Bitblocks.ChainFixtures.transaction_fixture(%{
        txid: txid,
        raw: hex,
        protocols: ["BCat"],
        block_height: 650_000
      })

      Enum.each(chunks, &publish/1)
      {:ok, row} = Bitblocks.CFiles.index_bcat(txid, 650_000)
      Base.encode16(row.sha256, case: :lower)
    end

    test "serves the assembled file, hashed again, under the same headers as /b/" do
      sha = bcat_indexed(["hello ", "from ", "the chain"])

      conn = build_conn() |> get("/c/#{sha}")

      assert response(conn, 200) == "hello from the chain"
      assert :crypto.hash(:sha256, conn.resp_body) |> Base.encode16(case: :lower) == sha
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") |> hd() =~ "sandbox"
      assert get_resp_header(conn, "cache-control") |> hd() =~ "immutable"
      assert get_resp_header(conn, "etag") == [~s("#{sha}")]
    end

    test "a chunk that can't be fetched just now is a 502 that says to try again" do
      # Indexed earlier; its chunk is held nowhere now, and WhatsOnChain can't answer.
      {txid, hex} = head([chunk("not held")])

      Bitblocks.ChainFixtures.transaction_fixture(%{
        txid: txid,
        raw: hex,
        protocols: ["BCat"],
        block_height: 650_000
      })

      file = %{
        data: "not held",
        vout: 0,
        chunks: 1,
        mime: "text/plain",
        charset: nil,
        filename: nil
      }

      row = Bitblocks.CFiles.bcat_row(txid, 650_000, file)
      Bitblocks.CFiles.write([row])
      sha = Base.encode16(row.sha256, case: :lower)
      Process.put(:woc_txs_error, :rate_limited)

      assert %{"error" => error} = build_conn() |> get("/c/#{sha}") |> json_response(502)
      assert error =~ "try again"
    end
  end
end
