defmodule BitblocksWeb.InteropLicenseTest do
  use BitblocksWeb.ConnCase, async: true

  test "the vectors' notice points at a licence we serve in full", %{conn: conn} do
    vectors = json_response(get(conn, "/interop/vectors/v1.json"), 200)
    assert vectors["licence_notice"] =~ "© BSV Association"

    path = URI.parse(vectors["licence_url"]).path
    text = response(get(conn, path), 200)

    assert text =~ "Open BSV License Version 6"
    assert text =~ "may only be used exclusively on the BSV Blockchain"
  end

  test "the live socket bounds a frame" do
    {_path, _socket, opts} =
      Enum.find(BitblocksWeb.Endpoint.__sockets__(), &(elem(&1, 0) == "/live"))

    assert opts[:websocket][:max_frame_size] == 12_000_000
  end
end
