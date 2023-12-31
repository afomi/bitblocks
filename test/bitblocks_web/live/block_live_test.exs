defmodule BitblocksWeb.BlockLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  @create_attrs %{size: 42, timestamp: %{month: 12, day: 30, year: 2023, minute: 27, hour: 20}, version: 42, time: 42, bits: "some bits", hash: "some hash", num_tx: 42, chainwork: "some chainwork", difficulty: 42, height: 42, mediantime: 42, merkleroot: "some merkleroot", nextblockhash: "some nextblockhash", prevblockhash: "some prevblockhash", nonce: 42}
  @update_attrs %{size: 43, timestamp: %{month: 12, day: 31, year: 2023, minute: 27, hour: 20}, version: 43, time: 43, bits: "some updated bits", hash: "some updated hash", num_tx: 43, chainwork: "some updated chainwork", difficulty: 43, height: 43, mediantime: 43, merkleroot: "some updated merkleroot", nextblockhash: "some updated nextblockhash", prevblockhash: "some updated prevblockhash", nonce: 43}
  @invalid_attrs %{size: nil, timestamp: %{month: 2, day: 30, year: 2023, minute: 27, hour: 20}, version: nil, time: nil, bits: nil, hash: nil, num_tx: nil, chainwork: nil, difficulty: nil, height: nil, mediantime: nil, merkleroot: nil, nextblockhash: nil, prevblockhash: nil, nonce: nil}

  defp create_block(_) do
    block = block_fixture()
    %{block: block}
  end

  describe "Index" do
    setup [:create_block]

    test "lists all blocks", %{conn: conn, block: block} do
      {:ok, _index_live, html} = live(conn, Routes.block_index_path(conn, :index))

      assert html =~ "Listing Blocks"
      assert html =~ block.bits
    end

    test "saves new block", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, Routes.block_index_path(conn, :index))

      assert index_live |> element("a", "New Block") |> render_click() =~
               "New Block"

      assert_patch(index_live, Routes.block_index_path(conn, :new))

      assert index_live
             |> form("#block-form", block: @invalid_attrs)
             |> render_change() =~ "is invalid"

      {:ok, _, html} =
        index_live
        |> form("#block-form", block: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.block_index_path(conn, :index))

      assert html =~ "Block created successfully"
      assert html =~ "some bits"
    end

    test "updates block in listing", %{conn: conn, block: block} do
      {:ok, index_live, _html} = live(conn, Routes.block_index_path(conn, :index))

      assert index_live |> element("#block-#{block.id} a", "Edit") |> render_click() =~
               "Edit Block"

      assert_patch(index_live, Routes.block_index_path(conn, :edit, block))

      assert index_live
             |> form("#block-form", block: @invalid_attrs)
             |> render_change() =~ "is invalid"

      {:ok, _, html} =
        index_live
        |> form("#block-form", block: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.block_index_path(conn, :index))

      assert html =~ "Block updated successfully"
      assert html =~ "some updated bits"
    end

    test "deletes block in listing", %{conn: conn, block: block} do
      {:ok, index_live, _html} = live(conn, Routes.block_index_path(conn, :index))

      assert index_live |> element("#block-#{block.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#block-#{block.id}")
    end
  end

  describe "Show" do
    setup [:create_block]

    test "displays block", %{conn: conn, block: block} do
      {:ok, _show_live, html} = live(conn, Routes.block_show_path(conn, :show, block))

      assert html =~ "Show Block"
      assert html =~ block.bits
    end

    test "updates block within modal", %{conn: conn, block: block} do
      {:ok, show_live, _html} = live(conn, Routes.block_show_path(conn, :show, block))

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Block"

      assert_patch(show_live, Routes.block_show_path(conn, :edit, block))

      assert show_live
             |> form("#block-form", block: @invalid_attrs)
             |> render_change() =~ "is invalid"

      {:ok, _, html} =
        show_live
        |> form("#block-form", block: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.block_show_path(conn, :show, block))

      assert html =~ "Block updated successfully"
      assert html =~ "some updated bits"
    end
  end
end
