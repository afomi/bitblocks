defmodule BitblocksWeb.BitcomLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Bitblocks.BitcomFixtures

  setup do
    admin = BSV.PrivKey.new()
    %{admin: admin, admin_addr: address(admin)}
  end

  test "the directory lists namespaces with their tier", %{conn: conn} = ctx do
    bitcom_command_fixture(ctx.admin, [["$", "useradd", ctx.admin_addr]])

    {:ok, view, html} = live(conn, ~p"/bitcom")

    assert html =~ "Bitcom Registry"
    assert has_element?(view, "#bitcom-#{ctx.admin_addr}", "proven")
  end

  test "the B:// home lists its recent txs newest first, and points to /files", %{conn: conn} do
    older = Bitblocks.ChainFixtures.transaction_fixture(%{protocols: ["B://"], block_height: 7})
    newer = Bitblocks.ChainFixtures.transaction_fixture(%{protocols: ["B://"], block_height: 8})
    Bitblocks.ChainFixtures.transaction_fixture(%{protocols: ["MAP"], block_height: 9})

    {:ok, view, _html} = live(conn, ~p"/bitcom/19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut")
    html = render_async(view)

    assert {:ok, [%{txid: first}, %{txid: second}]} =
             Bitblocks.Bitcom.recent_transactions("19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut")

    assert {first, second} == {newer.txid, older.txid}
    assert html =~ newer.txid
    assert html =~ ~s(href="/files")
    refute html =~ "couldn&#39;t be read"
    refute has_element?(view, "#bitcom-recent-loading")
  end

  test "the recent txs load after the page renders", %{conn: conn} do
    tx = Bitblocks.ChainFixtures.transaction_fixture(%{protocols: ["MAP"], block_height: 9})

    first = conn |> get(~p"/bitcom/1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5") |> html_response(200)
    assert first =~ "Reading the index"
    refute first =~ tx.txid

    {:ok, view, _html} = live(conn, ~p"/bitcom/1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5")
    assert render_async(view) =~ tx.txid
  end

  test "a home page shows proof, files, routes, and the command log", %{conn: conn} = ctx do
    provider = BSV.PrivKey.new()
    {proof, _} = bitcom_command_fixture(ctx.admin, [["$", "useradd", ctx.admin_addr]], salt: 1)
    bitcom_command_fixture(ctx.admin, [["$", "echo", "# My protocol", "to", "readme"]], salt: 2)
    bitcom_command_fixture(ctx.admin, [["$", "route", "enable", "/:tx"]], salt: 3)

    bitcom_command_fixture(
      provider,
      [["$", "route", "add", ctx.admin_addr, "/:tx", "https://cdn.example/${tx}"]],
      salt: 4
    )

    {:ok, view, html} = live(conn, ~p"/bitcom/#{ctx.admin_addr}")

    assert html =~ String.slice(proof.txid, 0, 12)
    assert has_element?(view, "#file-readme", "# My protocol")
    assert html =~ "bit://#{ctx.admin_addr}/:tx"
    assert html =~ "https://cdn.example/${tx}"
    assert html =~ "Command log"
  end

  test "an invalid address renders not-found", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/bitcom/not-an-address")
    assert html =~ "Not a Bitcom address"
  end

  describe "/bitcom/compose" do
    test "builds the output for the funding address", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/bitcom/compose")

      html =
        view
        |> form("#compose-form",
          compose: %{funder: ctx.admin_addr, command: "useradd"}
        )
        |> render_change()

      {:ok, expected} = Bitblocks.Bitcom.compose(["useradd", ctx.admin_addr], ctx.admin_addr)
      assert has_element?(view, "#compose-hex", expected.script_hex)
      assert html =~ ctx.admin_addr
    end

    test "explains why a command is invalid", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/bitcom/compose")

      view
      |> form("#compose-form", compose: %{funder: ctx.admin_addr, command: "echo"})
      |> render_change()

      assert view
             |> form("#compose-form",
               compose: %{funder: ctx.admin_addr, command: "echo", content: "x", file: ""}
             )
             |> render_change() =~ "malformed echo"
    end
  end
end
