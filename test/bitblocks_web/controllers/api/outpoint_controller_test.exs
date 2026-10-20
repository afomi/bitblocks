defmodule BitblocksWeb.Api.OutpointControllerTest do
  use BitblocksWeb.ConnCase, async: true

  alias Bitblocks.Chain.Transaction
  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.Repo

  @pkh :binary.copy(<<7>>, 20)
  @p2pkh [:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]

  defp envelope(content_type, body),
    do: [:OP_FALSE, :OP_IF, "ord", :OP_1, content_type, :OP_0, body, :OP_ENDIF] ++ @p2pkh

  # Stores a tx whose outputs are `[{chunks, satoshis}, ...]`; returns its txid.
  defp store_tx(outputs) do
    tx = %BSV.Tx{
      version: 1,
      inputs: [],
      lock_time: 0,
      outputs:
        Enum.map(outputs, fn {chunks, sats} ->
          %BSV.TxOut{script: %BSV.Script{chunks: chunks}, satoshis: sats}
        end)
    }

    raw = BSV.Tx.to_binary(tx, encoding: :hex)
    txid = tx |> BSV.Tx.get_txid()

    {:ok, _} =
      Repo.insert(
        Transaction.changeset(%Transaction{}, %{
          txid: txid,
          raw: raw,
          version: "1",
          inputs: [],
          outputs: [],
          block_height: 1,
          block_hash: String.duplicate("b", 64)
        })
      )

    txid
  end

  defp classify(conn, txid, vout),
    do:
      conn |> get(~p"/api/v1/outpoints/#{txid}/#{vout}") |> json_response(200) |> Map.get("data")

  test "no: indexed multi-sat output with no envelope", %{conn: conn} do
    txid = store_tx([{@p2pkh, 50_000}])
    assert %{"answer" => "no", "kind" => nil, "vout" => 0} = classify(conn, txid, 0)
  end

  test "yes/ordinal: output carries a non-token inscription", %{conn: conn} do
    txid = store_tx([{envelope("text/plain", "hello"), 1}])
    assert %{"answer" => "yes", "kind" => "ordinal"} = classify(conn, txid, 0)
  end

  test "yes/bsv-21: output carries a token inscription", %{conn: conn} do
    body = ~s({"p":"bsv-20","op":"deploy+mint","amt":"1000","sym":"T"})
    txid = store_tx([{envelope("application/bsv-20", body), 1}])
    assert %{"answer" => "yes", "kind" => "bsv-21"} = classify(conn, txid, 0)
  end

  test "yes: a protocol instance is indexed at a plain 1-sat outpoint", %{conn: conn} do
    txid = store_tx([{@p2pkh, 1}])
    protocol = ProtocolRegistry.get_protocol_by_name("BSV20")

    {:ok, _} =
      ProtocolRegistry.create_instance(%{
        protocol_id: protocol.id,
        txid: txid,
        vout: 0,
        parsed_data: %{"standard" => "bsv-21", "op" => "transfer"},
        state: %{}
      })

    assert %{"answer" => "yes", "kind" => "bsv-21"} = classify(conn, txid, 0)
  end

  test "unknown: bare 1-sat output (sat lineage not traced)", %{conn: conn} do
    txid = store_tx([{@p2pkh, 1}])
    assert %{"answer" => "unknown", "kind" => nil} = classify(conn, txid, 0)
  end

  test "unknown: transaction not indexed", %{conn: conn} do
    assert %{"answer" => "unknown", "reason" => "transaction not indexed"} =
             classify(conn, String.duplicate("a", 64), 0)
  end

  test "classifies each output of a mixed tx independently", %{conn: conn} do
    txid = store_tx([{envelope("text/plain", "hi"), 1}, {@p2pkh, 9_000}])
    assert %{"answer" => "yes"} = classify(conn, txid, 0)
    assert %{"answer" => "no"} = classify(conn, txid, 1)
  end

  test "404 when vout is past the last output", %{conn: conn} do
    txid = store_tx([{@p2pkh, 5}])
    assert conn |> get(~p"/api/v1/outpoints/#{txid}/1") |> json_response(404)
  end

  test "400 on a malformed txid or vout", %{conn: conn} do
    assert conn |> get(~p"/api/v1/outpoints/nothex/0") |> json_response(400)

    assert build_conn()
           |> get(~p"/api/v1/outpoints/#{String.duplicate("a", 64)}/-1")
           |> json_response(400)

    assert build_conn()
           |> get(~p"/api/v1/outpoints/#{String.duplicate("a", 64)}/x")
           |> json_response(400)
  end
end
