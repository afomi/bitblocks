defmodule BitblocksWeb.FlowTileControllerTest do
  @moduledoc """
  Flow tiles for `/tx-graph` are served from the ETS cache, and a tile request
  for a range makes no `transactions` query, nor any other (#67).
  """
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainTileFixtures

  alias Bitblocks.ChainTiles.Cache
  alias Bitblocks.FlowTiles

  setup do
    Cache.clear()
    on_exit(fn -> Cache.clear() end)
    :ok
  end

  defp queries_during(fun) do
    test_pid = self()
    id = "flow-tile-queries-#{inspect(test_pid)}"

    :telemetry.attach(
      id,
      [:bitblocks, :repo, :query],
      fn _event, _measure, meta, _ ->
        if self() == test_pid, do: send(test_pid, {:query, meta.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain([])
  end

  defp drain(acc) do
    receive do
      {:query, sql} -> drain([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "the manifest is a 404 until a build has run", %{conn: conn} do
    body = conn |> get("/chain-scrubber/flow-tiles/manifest") |> json_response(404)
    assert body["error"] == "not_built"
  end

  test "a range's manifest and tiles make no database query", %{conn: conn} do
    insert_blocks(0..2_100, num_tx: 1)
    {:ok, _} = FlowTiles.build(from: 0, through: 2_100)

    queries =
      queries_during(fn ->
        manifest = conn |> get("/chain-scrubber/flow-tiles/manifest") |> json_response(200)
        assert manifest["built_through"] == 2_100
        assert length(manifest["tiles"]) == 3

        for {hash, idx} <- Enum.with_index(manifest["tiles"]) do
          tile = get(build_conn(), "/chain-scrubber/flow-tiles/#{idx}?v=#{hash}")
          assert tile.status == 200
          assert get_resp_header(tile, "content-type") |> hd() =~ "application/octet-stream"

          assert get_resp_header(tile, "cache-control") == [
                   "private, max-age=31536000, immutable"
                 ]

          assert {:ok, %{first_height: first}, records} =
                   FlowTiles.Codec.decode(tile.resp_body)

          assert first == idx * 1024
          assert Enum.all?(records, &(&1.num_tx == 1))
        end
      end)

    assert queries == [], "flow tile requests queried the database: #{inspect(queries)}"
  end

  test "a stale hash or an unknown tile is a 404", %{conn: conn} do
    insert_blocks(0..10, num_tx: 1)
    {:ok, _} = FlowTiles.build(from: 0, through: 10)

    assert conn |> get("/chain-scrubber/flow-tiles/0?v=stale") |> json_response(404)
    assert build_conn() |> get("/chain-scrubber/flow-tiles/7") |> json_response(404)
    assert build_conn() |> get("/chain-scrubber/flow-tiles/x") |> json_response(404)
  end
end
