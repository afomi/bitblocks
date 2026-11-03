defmodule BitblocksWeb.ChainTileControllerTest do
  @moduledoc """
  Chain-scrubber tiles are served from the ETS cache behind admin auth, and a
  tile request makes no database query (#48).
  """
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainTileFixtures

  alias Bitblocks.ChainTiles
  alias Bitblocks.ChainTiles.Cache

  setup do
    Cache.clear()
    on_exit(fn -> Cache.clear() end)
    :ok
  end

  defp count_queries(fun) do
    test_pid = self()
    id = "chain-tile-queries-#{inspect(test_pid)}"

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

  test "the manifest is a 404 until tiles are built", %{conn: conn} do
    conn = get(conn, "/chain-scrubber/tiles/manifest")
    assert json_response(conn, 404)["error"] == "not_built"
  end

  test "manifest and tile requests make no database query", %{conn: conn} do
    insert_blocks(0..1_100)
    {:ok, _} = ChainTiles.build(mode: :full)

    queries =
      count_queries(fn ->
        manifest = conn |> get("/chain-scrubber/tiles/manifest") |> json_response(200)
        assert manifest["tip_height"] == 1_100
        assert [%{"level" => 0, "span" => 1, "tiles" => [hash0, _hash1]} | _] = manifest["levels"]

        tile = get(build_conn(), "/chain-scrubber/tiles/0/0?v=#{hash0}")
        assert tile.status == 200
        assert get_resp_header(tile, "content-type") |> hd() =~ "application/octet-stream"
        assert get_resp_header(tile, "cache-control") == ["private, max-age=31536000, immutable"]
        assert byte_size(tile.resp_body) == 16_416

        assert {:ok, %{level: 0, first_height: 0, count: 1024}, _} =
                 ChainTiles.Codec.decode(tile.resp_body)

        for level <- 1..3 do
          assert get(build_conn(), "/chain-scrubber/tiles/#{level}/0").status == 200
        end
      end)

    assert queries == [], "tile requests queried the database: #{inspect(queries)}"
  end

  test "a stale content hash is a 404, so the client refetches the manifest", %{conn: conn} do
    insert_blocks(0..10)
    {:ok, _} = ChainTiles.build(mode: :full)

    assert get(conn, "/chain-scrubber/tiles/0/0?v=0000000000000000").status == 404
    assert get(conn, "/chain-scrubber/tiles/0/99").status == 404
    assert get(conn, "/chain-scrubber/tiles/x/0").status == 404
    assert get(conn, "/chain-scrubber/tiles/0/0").status == 200
  end

  describe "with admin auth enabled" do
    setup do
      previous = Application.get_env(:bitblocks, :admin_auth)
      Application.put_env(:bitblocks, :admin_auth, enabled: true)
      on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, previous) end)
      :ok
    end

    test "anonymous tile requests get the auth challenge", %{conn: conn} do
      conn = get(conn, "/chain-scrubber/tiles/manifest")
      assert conn.status == 401
      assert [_ | _] = get_resp_header(conn, "www-authenticate")

      assert get(build_conn(), "/chain-scrubber/tiles/0/0").status == 401
    end

    test "credentials pass, still without a database query", %{conn: conn} do
      insert_blocks(0..10)
      {:ok, _} = ChainTiles.build(mode: :full)
      {:ok, user, pass} = BitblocksWeb.AdminAuth.decision()

      queries =
        count_queries(fn ->
          conn =
            conn
            |> put_req_header("authorization", "Basic " <> Base.encode64("#{user}:#{pass}"))
            |> get("/chain-scrubber/tiles/0/0")

          assert conn.status == 200
        end)

      assert queries == []
    end
  end
end
