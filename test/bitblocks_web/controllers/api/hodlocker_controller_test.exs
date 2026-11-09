defmodule BitblocksWeb.Api.HodlockerControllerTest do
  # GET /api/v1/hodlocker/posts/:txid (#76): what the indexed locks back a
  # post with, from real HodLocker txs (test/support/data/hodlocker_txs.json).
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Timelocks

  @txs "test/support/data/hodlocker_txs.json"
       |> File.read!()
       |> Jason.decode!()
       |> Map.fetch!("txs")
       |> Map.new(&{&1["txid"], &1})

  @post "f76b5b61f8c2d643d10aad4dd7256090c986799293447080041a23145d253ed9"
  @like "7f496c643364501f7b1c3f1593fd827b6e2af7207b3ead3ec04bb5666c16a88b"

  setup do
    # The post and the like were mined in the same block, our tip here.
    block = block_fixture(height: 833_405)

    for txid <- [@post, @like] do
      tx =
        transaction_fixture(
          txid: txid,
          raw: @txs[txid]["raw"],
          block_hash: block.hash,
          block_height: block.height
        )

      Timelocks.index(tx, block)
    end

    :ok
  end

  test "a post's totals: sats, locks, likes, and what is still locked", %{conn: conn} do
    body = conn |> get(~p"/api/v1/hodlocker/posts/#{@post}") |> json_response(200)

    assert %{
             "data" => %{
               "post_txid" => @post,
               "satoshis" => 2_100_000_001,
               "locked_satoshis" => 2_100_000_001,
               "locks" => 2,
               "txs" => 2,
               "likes" => 1,
               "first_unlock_height" => 833_548,
               "last_unlock_height" => 858_404
             },
             "meta" => %{"tip_height" => 833_405, "source" => "timelocks"}
           } = body
  end

  test "a txid no indexed lock backs has zero totals", %{conn: conn} do
    body =
      conn |> get(~p"/api/v1/hodlocker/posts/#{String.duplicate("0", 64)}") |> json_response(200)

    assert %{"data" => %{"satoshis" => 0, "locks" => 0, "likes" => 0}} = body
  end

  test "anything but a txid is a 400", %{conn: conn} do
    assert %{"error" => _} =
             conn |> get(~p"/api/v1/hodlocker/posts/not-a-txid") |> json_response(400)
  end
end
