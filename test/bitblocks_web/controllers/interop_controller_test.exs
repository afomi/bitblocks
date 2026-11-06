defmodule BitblocksWeb.InteropControllerTest do
  use BitblocksWeb.ConnCase, async: false

  alias Bitblocks.Interop.Vectors

  @path "/interop/vectors/v1.json"

  defp with_gate(fun) do
    Application.put_env(:bitblocks, :admin_auth, enabled: true)
    on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, enabled: false) end)
    fun.()
  end

  test "open to anyone, with no key or session", %{conn: conn} do
    with_gate(fn ->
      conn = get(conn, @path)

      assert response(conn, 200) == Vectors.body()
      assert response_content_type(conn, :json)
      assert %{"name" => "bitblocks-interop-vectors"} = json_response(conn, 200)
    end)
  end

  test "any origin can read it, and caches can hold it", %{conn: conn} do
    conn = conn |> put_req_header("origin", "https://example.org") |> get(@path)

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "etag") == [~s("#{Vectors.sha256()}")]
  end

  test "a cached copy gets a 304 and no body", %{conn: conn} do
    conn = conn |> put_req_header("if-none-match", ~s("#{Vectors.sha256()}")) |> get(@path)

    assert response(conn, 304) == ""
  end

  test "reads no database", %{conn: conn} do
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:bitblocks, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:query, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The endpoint's plugs may look up a caller; the route itself must not query.
    assert conn |> get(@path) |> response(200)
    refute_received {:query, _}
  end
end
