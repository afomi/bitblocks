defmodule BitblocksWeb.Api.BeefControllerTest do
  use BitblocksWeb.ConnCase, async: false

  alias Bitblocks.RealHeaders

  @fixtures Path.expand("../../../support/fixtures/brc", __DIR__)
  @path "/api/v1/beef/verify"

  defp brc62 do
    @fixtures
    |> Path.join("brc62_beef.hex")
    |> File.read!()
    |> String.trim()
    |> Base.decode16!(case: :lower)
  end

  defp post_raw(conn, bytes) do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> post(@path, bytes)
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@path, Jason.encode!(body))
  end

  defp with_limit(bytes) do
    previous = Application.get_env(:bitblocks, :beef_verify_max_bytes)
    Application.put_env(:bitblocks, :beef_verify_max_bytes, bytes)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bitblocks, :beef_verify_max_bytes, previous),
        else: Application.delete_env(:bitblocks, :beef_verify_max_bytes)
    end)
  end

  describe "a BEEF" do
    test "as raw bytes, against a header we hold", %{conn: conn} do
      RealHeaders.insert(814_435)

      data = conn |> post_raw(brc62()) |> json_response(200) |> Map.fetch!("data")

      assert data["status"] == "anchored"
      assert data["format"] == "beef_v1"
      assert data["in_block"] == false
      assert data["claim"] =~ "Inclusion in a block only"
      assert "scripts" in data["not_checked"]

      assert [%{"status" => "proven", "block_height" => 814_435} = parent, _] =
               data["transactions"]

      assert data["proven"] == [parent["txid"]]
    end

    test "as hex in JSON gives the same answer, in either case", %{conn: conn} do
      RealHeaders.insert(814_435)
      raw = conn |> post_raw(brc62()) |> json_response(200)

      for hex <- [
            Base.encode16(brc62(), case: :lower),
            Base.encode16(brc62(), case: :upper)
          ] do
        assert build_conn() |> post_json(%{beef: hex}) |> json_response(200) == raw
      end
    end

    test "with a charset on its content type", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json; charset=utf-8")
        |> post(@path, Jason.encode!(%{beef: Base.encode16(brc62())}))

      assert json_response(conn, 200)
    end

    test "at a height we don't hold is unknown, and nothing says valid", %{conn: conn} do
      body = conn |> post_raw(brc62()) |> json_response(200)

      assert body["data"]["status"] == "unknown"
      assert body["data"]["proven"] == []
      refute Enum.any?(body["data"]["transactions"], &(&1["status"] == "valid"))
    end
  end

  describe "refused" do
    test "bytes that aren't a BEEF are a 422 with a reason", %{conn: conn} do
      conn = post_raw(conn, brc62() <> <<0>>)

      assert %{"reason" => "trailing_bytes"} = json_response(conn, 422)
    end

    test "an empty body is a 422", %{conn: conn} do
      assert %{"reason" => "truncated"} = conn |> post_raw("") |> json_response(422)
    end

    test "hex that isn't hex is a 400", %{conn: conn} do
      assert conn |> post_json(%{beef: "not hex"}) |> json_response(400)
    end

    test "JSON without a beef string is a 400", %{conn: conn} do
      assert conn |> post_json(%{other: 1}) |> json_response(400)
      assert build_conn() |> post_json(%{beef: 1}) |> json_response(400)
      assert build_conn() |> post_json([1, 2]) |> json_response(400)
    end

    test "a beef in the query string isn't read", %{conn: conn} do
      hex = Base.encode16(brc62(), case: :lower)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(@path <> "?beef=#{hex}", "{}")

      assert json_response(conn, 400)
    end

    test "any other content type is a 415", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post(@path, "beef=00")

      assert json_response(conn, 415)["error"] =~ "application/octet-stream"

      conn =
        build_conn()
        |> put_req_header("content-type", "text/plain")
        |> post(@path, "0100beef")

      assert json_response(conn, 415)
    end

    test "no content type is a 415", %{conn: conn} do
      assert conn |> post(@path) |> json_response(415)
    end
  end

  describe "the size limit" do
    test "raw bytes over the limit are a 413", %{conn: conn} do
      with_limit(100)

      assert %{"reason" => "too_large"} = conn |> post_raw(brc62()) |> json_response(413)
    end

    test "a declared length over the limit is a 413 without reading", %{conn: conn} do
      with_limit(100)

      conn = conn |> put_req_header("content-length", "5000000") |> post_raw(<<0>>)

      assert json_response(conn, 413)
    end

    test "a limit met exactly is read", %{conn: conn} do
      with_limit(byte_size(brc62()))

      assert conn |> post_raw(brc62()) |> json_response(200)
    end

    test "hex over the limit is a 413", %{conn: conn} do
      with_limit(100)

      conn = post_json(conn, %{beef: Base.encode16(brc62(), case: :lower)})

      assert %{"reason" => "too_large"} = json_response(conn, 413)
    end

    test "the default limit refuses a body past 4 MB", %{conn: conn} do
      assert conn
             |> post_raw(:binary.copy(<<0>>, 4_000_001))
             |> json_response(413)
    end
  end

  describe "the gate" do
    setup do
      :ets.delete_all_objects(:rate_limiter)
      previous = Application.get_env(:bitblocks, :admin_auth)
      Application.put_env(:bitblocks, :admin_auth, enabled: true)
      on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, previous) end)
    end

    test "signed out is a 401, and the body isn't read", %{conn: conn} do
      conn = post_raw(conn, brc62())

      assert conn.status == 401
      assert json_response(conn, 401)["error"] =~ "API key"
    end
  end
end
