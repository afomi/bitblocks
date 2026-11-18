defmodule BitblocksWeb.Api.ProjectionCommandsTest do
  @moduledoc """
  #29 Tenant 3 over HTTP: hydrate the Bitcom command log at
  `/api/v1/projections/:id/commands` and follow it over SSE as `command` events.
  """
  # async: false — the stream config and the "blocks" PubSub topic are shared.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Bitcom.Command
  alias Bitblocks.Chain
  alias Bitblocks.Projections
  alias Bitblocks.Repo

  @actor "1BitcomActorXXXXXXXXXXXXXXXXXXXXX"

  setup do
    Application.put_env(:bitblocks, BitblocksWeb.Api.StreamController,
      heartbeat_ms: 200,
      max_lifetime_ms: 0
    )

    on_exit(fn -> Application.delete_env(:bitblocks, BitblocksWeb.Api.StreamController) end)

    {:ok, p} = Projections.create(%{tenant: "bitcom", name: "log", source: "bitcom_commands"})

    for h <- [10, 11, 12],
        do: block_fixture(%{height: h, hash: "block_#{h}", sync_state: "completed"})

    command(11, "1", "useradd", [@actor])
    command(12, "2", "echo", ["hi", "to", "readme"])

    %{projection: p}
  end

  defp command(height, n, word, args) do
    txid = String.duplicate(n, 64)
    transaction_fixture(%{block_height: height, block_hash: "block_#{height}", txid: txid})

    Repo.insert!(%Command{
      txid: txid,
      output_index: 0,
      block_height: height,
      actor: @actor,
      namespace: @actor,
      command: word,
      args: args,
      valid: true
    })
  end

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

  test "GET /commands hydrates the log with a cursor", %{conn: conn, projection: p} do
    body = conn |> get(~p"/api/v1/projections/#{p.id}/commands?limit=1") |> json_response(200)

    assert [%{"command" => "useradd", "block_height" => 11, "block_hash" => "block_11"} = c] =
             body["data"]

    assert c["txid"] == String.duplicate("1", 64)
    assert c["output_index"] == 0
    assert c["namespace"] == @actor
    assert c["args"] == [@actor]
    assert c["valid"] == true
    assert c["proof_url"] == "/api/v1/txs/#{c["txid"]}/proof"
    assert %{"source" => "bitcom_commands", "snapshot_height" => 12} = body["meta"]

    next = body["meta"]["next_cursor"]

    second =
      conn
      |> get(~p"/api/v1/projections/#{p.id}/commands?limit=1&cursor=#{next}")
      |> json_response(200)

    assert [%{"command" => "echo", "block_height" => 12}] = second["data"]
    assert second["meta"]["next_cursor"] == nil
  end

  test "each hydrate path names the other for the wrong source", %{conn: conn, projection: p} do
    assert %{"hydrate" => path} =
             conn |> get(~p"/api/v1/projections/#{p.id}/txs") |> json_response(400)

    assert path == "/api/v1/projections/#{p.id}/commands"

    {:ok, txp} = Projections.create(%{tenant: "t", name: "n", filter: %{"protocols" => ["x"]}})

    assert %{"hydrate" => path} =
             conn |> get(~p"/api/v1/projections/#{txp.id}/commands") |> json_response(400)

    assert path == "/api/v1/projections/#{txp.id}/txs"
  end

  test "GET /:id and /status describe a command projection", %{conn: conn, projection: p} do
    data = conn |> get(~p"/api/v1/projections/#{p.id}") |> json_response(200) |> Map.get("data")
    assert %{"source" => "bitcom_commands", "filter" => %{}, "hydrate_url" => url} = data
    assert url == "/api/v1/projections/#{p.id}/commands"

    status = conn |> get(~p"/api/v1/projections/#{p.id}/status") |> json_response(200)
    assert %{"data" => %{"stable_through_height" => -1, "index_state" => "backfilling"}} = status
  end

  test "follow catches up as command events, then checkpoints", %{conn: conn, projection: p} do
    conn = follow(conn, ~p"/api/v1/projections/#{p.id}/follow?after_height=10")

    assert [
             {"command", nil, %{"command" => "useradd", "block_height" => 11}},
             {"command", nil, %{"command" => "echo", "block_height" => 12}},
             {"checkpoint", "12", %{"resume_height" => 12}}
           ] = events(conn.resp_body)
  end

  test "follow emits a new block's command as it completes", %{conn: conn, projection: p} do
    publish = fn ->
      block = block_fixture(%{height: 13, hash: "block_13", sync_state: "completed"})
      command(13, "3", "route", ["enable", "/:tx"])
      Chain.broadcast_block_update(block)
    end

    conn = follow(conn, ~p"/api/v1/projections/#{p.id}/follow", publish)

    assert [
             {"checkpoint", "12", _},
             {"command", nil,
              %{"command" => "route", "block_height" => 13, "block_hash" => "block_13"} = c},
             {"checkpoint", "13", %{"resume_height" => 13, "block_height" => 13}}
           ] = events(conn.resp_body)

    assert c["txid"] == String.duplicate("3", 64)
  end

  test "a reorg arrives with its rewind height", %{conn: conn, projection: p} do
    publish = fn -> Chain.broadcast_reorg(%{fork_point: 11, fork_height: 12, orphans: ["x"]}) end
    conn = follow(conn, ~p"/api/v1/projections/#{p.id}/follow", publish)

    assert [{"checkpoint", _, _}, {"reorg", nil, %{"rewind_height" => 11}}] =
             events(conn.resp_body)
  end

  test "too far behind is a 409 pointing at /commands", %{conn: conn, projection: p} do
    block_fixture(%{height: 5_000, hash: "block_5000", sync_state: "completed"})
    conn = get(conn, ~p"/api/v1/projections/#{p.id}/follow?after_height=10")

    assert %{"hydrate" => hydrate} = json_response(conn, 409)
    assert hydrate == "/api/v1/projections/#{p.id}/commands"
  end
end
