defmodule BitblocksWeb.BlockImportControllerTest do
  # Pushing an exported raw block to prod: the server takes the hash from the
  # bytes, runs the sync loop's checks and stores it; nothing is trusted from
  # the caller but the height.
  use BitblocksWeb.ConnCase, async: false

  alias Bitblocks.Chain.Block
  alias Bitblocks.Repo

  @genesis_hash "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
  @genesis_hex "0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c" <>
                 "01" <>
                 "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

  setup do
    BitblocksWeb.RpcStub.setup()
    BitblocksWeb.RpcStub.clear()
    :ok
  end

  defp push_block(conn, height, bytes) do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> post("/admin/blocks/#{height}", bytes)
  end

  test "stores a pushed block and says so", %{conn: conn} do
    body = conn |> push_block(0, Base.decode16!(@genesis_hex, case: :lower)) |> json_response(201)

    assert body == %{"height" => 0, "hash" => @genesis_hash, "result" => "completed"}
    assert Repo.get_by!(Block, height: 0).sync_state == "completed"
  end

  test "pushing the same block again is a no-op", %{conn: conn} do
    bytes = Base.decode16!(@genesis_hex, case: :lower)
    push_block(conn, 0, bytes)

    assert %{"result" => "already_complete"} =
             build_conn() |> push_block(0, bytes) |> json_response(200)
  end

  test "bytes that aren't a valid block are refused", %{conn: conn} do
    assert %{"error" => _} = conn |> push_block(0, "not a block") |> json_response(422)
    refute Repo.get_by(Block, height: 0)
  end

  test "is behind the admin gate" do
    Application.put_env(:bitblocks, :admin_auth, enabled: true)
    on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, enabled: false) end)

    conn = push_block(build_conn(), 0, Base.decode16!(@genesis_hex, case: :lower))
    assert conn.status in [401, 403]
    refute Repo.get_by(Block, height: 0)
  end
end
