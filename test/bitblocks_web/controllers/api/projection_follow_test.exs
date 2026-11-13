defmodule BitblocksWeb.Api.ProjectionFollowTest do
  # async: false — the stream config and the "blocks" PubSub topic are shared.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain
  alias Bitblocks.Projections

  @qart "1QartSignerXXXXXXXXXXXXXXXXXXXXXXX"

  setup do
    Application.put_env(:bitblocks, BitblocksWeb.Api.StreamController,
      heartbeat_ms: 200,
      max_lifetime_ms: 0
    )

    on_exit(fn -> Application.delete_env(:bitblocks, BitblocksWeb.Api.StreamController) end)

    # The AND filter qart needs: MAP and its own AIP signer.
    {:ok, p} =
      Projections.create(%{
        tenant: "qart",
        name: "listings",
        filter: %{"protocols" => ["MAP"], "aip_signers" => [@qart]}
      })

    for h <- [10, 11, 12],
        do: block_fixture(%{height: h, hash: "block_#{h}", sync_state: "completed"})

    tx(11, "1", ["MAP"], [@qart])
    # MAP without qart's signature: spoofed, never sent.
    tx(11, "2", ["MAP"], [])
    tx(12, "3", ["MAP"], [@qart])

    %{projection: p}
  end

  defp tx(height, n, protocols, signers) do
    transaction_fixture(%{
      block_height: height,
      block_hash: "block_#{height}",
      txid: String.duplicate(n, 64),
      protocols: protocols,
      aip_signers: signers
    })
  end

  # The handler blocks in this process; a spent lifetime ends it at the first
  # quiet moment after `publish` ran.
  defp follow(conn, path, publish \\ fn -> :ok end) do
    spawn_link(fn ->
      Process.sleep(50)
      publish.()
    end)

    get(conn, path)
  end

  defp events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn chunk ->
      lines = String.split(chunk, "\n")

      case Enum.find(lines, &String.starts_with?(&1, "event: ")) do
        nil ->
          []

        "event: " <> name ->
          id = Enum.find_value(lines, fn l -> String.starts_with?(l, "id: ") && l end)
          "data: " <> json = Enum.find(lines, &String.starts_with?(&1, "data: "))
          [{name, id && String.replace_prefix(id, "id: ", ""), Jason.decode!(json)}]
      end
    end)
    |> Enum.reject(fn {name, _, _} -> name == "reconnect" end)
  end

  test "catches up from after_height with the AND filter, then checkpoints", %{
    conn: conn,
    projection: p
  } do
    conn = follow(conn, ~p"/api/v1/projections/#{p.id}/follow?after_height=10")
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    assert [
             {"tx", nil, %{"txid" => t1, "block_height" => 11}},
             {"tx", nil, %{"txid" => t3, "block_height" => 12}},
             {"checkpoint", "12", %{"resume_height" => 12, "block_height" => nil}}
           ] = events(conn.resp_body)

    assert t1 == String.duplicate("1", 64)
    assert t3 == String.duplicate("3", 64)
  end

  test "Last-Event-ID resumes after it", %{conn: conn, projection: p} do
    conn =
      conn
      |> put_req_header("last-event-id", "11")
      |> follow(~p"/api/v1/projections/#{p.id}/follow")

    assert [{"tx", nil, %{"block_height" => 12}}, {"checkpoint", "12", _}] =
             events(conn.resp_body)
  end

  test "a block completing at the tip arrives as its txs and a checkpoint", %{
    conn: conn,
    projection: p
  } do
    publish = fn ->
      block = block_fixture(%{height: 13, hash: "block_13", sync_state: "completed"})
      tx(13, "4", ["MAP"], [@qart])
      Chain.broadcast_block_update(block)
    end

    conn = follow(conn, ~p"/api/v1/projections/#{p.id}/follow", publish)

    assert [
             {"checkpoint", "12", _},
             {"tx", nil, %{"block_height" => 13, "block_hash" => "block_13"}},
             {"checkpoint", "13", %{"resume_height" => 13, "block_height" => 13}}
           ] = events(conn.resp_body)
  end

  test "a block completing out of order holds the resume height back", %{
    conn: conn,
    projection: p
  } do
    publish = fn ->
      block_fixture(%{height: 13, hash: "block_13", sync_state: "header_only"})
      block = block_fixture(%{height: 14, hash: "block_14", sync_state: "completed"})
      Chain.broadcast_block_update(block)
    end

    conn = follow(conn, ~p"/api/v1/projections/#{p.id}/follow", publish)

    assert [
             {"checkpoint", "12", _},
             {"checkpoint", "12", %{"resume_height" => 12, "block_height" => 14}}
           ] = events(conn.resp_body)
  end

  test "a reorg arrives with its rewind height", %{conn: conn, projection: p} do
    publish = fn -> Chain.broadcast_reorg(%{fork_point: 11, fork_height: 12, orphans: ["x"]}) end
    conn = follow(conn, ~p"/api/v1/projections/#{p.id}/follow", publish)

    assert [{"checkpoint", _, _}, {"reorg", nil, %{"rewind_height" => 11}}] =
             events(conn.resp_body)
  end

  test "too far behind is a 409 pointing at hydrate", %{conn: conn, projection: p} do
    block_fixture(%{height: 5_000, hash: "block_5000", sync_state: "completed"})
    conn = get(conn, ~p"/api/v1/projections/#{p.id}/follow?after_height=10")

    assert %{"hydrate" => hydrate} = json_response(conn, 409)
    assert hydrate == "/api/v1/projections/#{p.id}/txs"
  end

  test "a bad position is a 400 and an unknown projection a 404", %{conn: conn, projection: p} do
    assert json_response(get(conn, ~p"/api/v1/projections/#{p.id}/follow?after_height=x"), 400)
    assert json_response(get(conn, ~p"/api/v1/projections/999999/follow"), 404)
  end
end
