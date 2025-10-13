defmodule BitblocksWeb.PageControllerTest do
  use BitblocksWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Bitblocks"
    assert response =~ "Bitcoin SV Blockchain Explorer"
    assert response =~ "Bitcoin Protocols"
    assert response =~ "Node status"
  end
end
