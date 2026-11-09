defmodule BitblocksWeb.Api.BobControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  # A real mainnet B:// + MAP tx (see test/bitblocks/bob_test.exs).
  @txid "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
  @hex "test/fixtures/bob/#{@txid}.hex" |> File.read!() |> String.trim()

  test "a stored tx in a chained block is its BOB, with blk", %{conn: conn} do
    block = block_fixture(%{sync_state: "completed", time: 1_565_131_423})

    transaction_fixture(%{
      txid: @txid,
      raw: @hex,
      block_hash: block.hash,
      block_height: block.height
    })

    conn = get(conn, "/api/v1/txs/#{@txid}/bob")
    data = json_response(conn, 200)["data"]

    assert data["tx"] == %{"h" => @txid}
    assert data["blk"] == %{"i" => block.height, "h" => block.hash, "t" => 1_565_131_423}
    assert [%{"e" => %{"a" => "17SnqQYGNZuD4zpu8eemt26TrdbvoJC5ie"}}] = data["in"]
    assert length(data["out"]) == 4
    assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
  end

  test "a tx we don't hold is read from WhatsOnChain, with no blk", %{conn: conn} do
    Process.put(:woc_txs, %{@txid => %{"txid" => @txid, "hex" => @hex}})

    data = conn |> get("/api/v1/txs/#{String.upcase(@txid)}/bob") |> json_response(200)
    refute Map.has_key?(data["data"], "blk")
    assert data["data"]["tx"]["h"] == @txid
  end

  test "an unknown tx is a 404, a bad txid a 400, an unreadable upstream a 502", %{conn: conn} do
    assert %{"error" => "unknown transaction"} =
             conn |> get("/api/v1/txs/#{String.duplicate("a", 64)}/bob") |> json_response(404)

    assert build_conn() |> get("/api/v1/txs/nope/bob") |> json_response(400)

    Process.put(:woc_txs_error, :timeout)

    assert build_conn()
           |> get("/api/v1/txs/#{String.duplicate("b", 64)}/bob")
           |> json_response(502)
  end
end
