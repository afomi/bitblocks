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
end
