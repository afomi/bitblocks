defmodule BitblocksWeb.FilesLiveTest do
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  # A real mainnet B:// + MAP tx (Twetch, 2019); see test/bitblocks/bob_test.exs.
  @txid "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
  @hex "test/fixtures/bob/#{@txid}.hex" |> File.read!() |> String.trim()

  test "lists a stored B:// file, opening at /b/:txid", %{conn: conn} do
    transaction_fixture(%{txid: @txid, raw: @hex, protocols: ["B://"], block_height: 594_000})

    {:ok, view, html} = live(conn, ~p"/files")

    assert html =~ "Files on Bitcoin"

    assert has_element?(
             view,
             ~s(#file-#{@txid} a[href="/b/#{@txid}"]),
             "twetch_twtext_1565131423556.txt"
           )

    assert has_element?(view, "#file-#{@txid}", "text/plain")
    assert has_element?(view, "#file-#{@txid}", "c://")
    refute has_element?(view, "#files-older")
  end

  test "says so when no file is stored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/files")
    assert has_element?(view, "#files-empty")
  end

  test "an unreadable before is the first page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/files?before=nope")
    assert has_element?(view, "#files-empty")
  end
end
