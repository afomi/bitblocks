defmodule BitblocksWeb.Api.ProofControllerTest do
  # RpcStub is one shared table, so not async.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures

  alias BitblocksWeb.RpcStub

  setup do
    RpcStub.setup()
    :ok
  end

  test "a stored tx gets the node's merkle proof, anchored to its block header", %{conn: conn} do
    block = block_fixture(%{merkleroot: String.duplicate("cd", 32)})
    tx = transaction_fixture(%{block_hash: block.hash, block_height: block.height})
    RpcStub.stub_gettxoutproof([tx.txid], block.hash, "00ff")

    data =
      conn |> get(~p"/api/v1/txs/#{tx.txid}/proof") |> json_response(200) |> Map.fetch!("data")

    assert data == %{
             "txid" => tx.txid,
             "block_hash" => block.hash,
             "block_height" => block.height,
             "merkleroot" => block.merkleroot,
             "proof" => "00ff"
           }
  end

  test "a tx we don't store is a 404, not a proof", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/txs/#{String.duplicate("ab", 32)}/proof")
    assert json_response(conn, 404)
  end

  test "a node that can't give the proof is a 404", %{conn: conn} do
    block = block_fixture()
    tx = transaction_fixture(%{block_hash: block.hash, block_height: block.height})

    assert conn |> get(~p"/api/v1/txs/#{tx.txid}/proof") |> json_response(404)
  end
end
