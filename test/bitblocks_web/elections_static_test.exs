defmodule BitblocksWeb.ElectionsStaticTest do
  @moduledoc """
  The recount tool and its guide are static files
  (https://github.com/afomi/bitblocks/issues/138), so they need no database
  and can be copied beside an archive.
  """
  use BitblocksWeb.ConnCase, async: true

  defp tool_source,
    do: File.read!(Application.app_dir(:bitblocks, "priv/static/elections/recount.py"))

  test "GET /elections/recount.py serves the tool, byte for byte", %{conn: conn} do
    conn = get(conn, "/elections/recount.py")
    assert conn.status == 200
    assert conn.resp_body == tool_source()
    assert conn.resp_body =~ "makes no network calls"
  end

  test "GET /elections/recount.html is the guide, linking the tool and the vectors",
       %{conn: conn} do
    conn = get(conn, "/elections/recount.html")
    assert html_response(conn, 200) =~ "Recount an election yourself"
    # Relative to the guide, and full URLs elsewhere, so the copy inside an
    # archive links the tool beside it and works from a file.
    assert conn.resp_body =~ ~s(href="recount.py")
    assert conn.resp_body =~ ~s(href="https://bitblocks.app/interop/elections/count/v0.json")
    refute conn.resp_body =~ ~r/(href|src)="\//
  end

  test "the tool imports no network module" do
    for module <- ~w(socket urllib http requests ssl ftplib smtplib subprocess) do
      refute tool_source() =~ ~r/^\s*(import|from) #{module}\b/m, "recount.py imports #{module}"
    end
  end
end
