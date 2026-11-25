defmodule BitblocksWeb.FilesLiveTest do
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  # A real mainnet B:// + MAP tx (Twetch, 2019); see test/bitblocks/bob_test.exs.
  @txid "7e5011d81d01c67e81ab9a50ab3077bb62b340d1b50592931e4b52afa7198e65"
  @hex "test/fixtures/bob/#{@txid}.hex" |> File.read!() |> String.trim()

  test "lists a stored B:// file, opening at /b/:txid and at its C:// address", %{conn: conn} do
    transaction_fixture(%{txid: @txid, raw: @hex, protocols: ["B://"], block_height: 594_000})

    {:ok, view, html} = live(conn, ~p"/files")

    assert html =~ "Files on Bitcoin"

    assert has_element?(
             view,
             ~s(#file-#{@txid} a[href="/b/#{@txid}"]),
             "twetch_twtext_1565131423556.txt"
           )

    assert has_element?(view, "#file-#{@txid}", "text/plain")
    sha = :crypto.hash(:sha256, "HAHAHAHA") |> Base.encode16(case: :lower)
    assert has_element?(view, ~s(#file-#{@txid} a[href="/c/#{sha}"]), "c://")
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

  describe "find a file (#175)" do
    alias Bitblocks.CFiles

    defp put(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      content = attrs[:content] || attrs[:filename]

      row = %{
        sha256: :crypto.hash(:sha256, content),
        txid: attrs[:txid] || Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        vout: 0,
        block_height: Map.get(attrs, :block_height, 640_000),
        kind: attrs[:kind] || "b",
        chunks: attrs[:chunks],
        media_type: Map.get(attrs, :media_type, "text/plain"),
        encoding: nil,
        filename: attrs[:filename],
        size: byte_size(content),
        version: CFiles.version(),
        inserted_at: now,
        updated_at: now
      }

      CFiles.write([row])
      row
    end

    defp text(view, selector),
      do: view |> element(selector) |> render() |> Floki.parse_fragment!() |> Floki.text()

    test "searches by name from the box, with each result's links", %{conn: conn} do
      cat = put(%{filename: "cat.png", media_type: "image/png", block_height: 641_000})

      bcat =
        put(%{filename: "concat.mp4", media_type: "video/mp4", kind: "bcat", chunks: 3})

      put(%{filename: "dog.txt"})

      {:ok, view, _html} = live(conn, ~p"/files")
      assert has_element?(view, ~s(label[for="files-q"]), "Find a file")
      assert has_element?(view, ~s(#files-type option[value="image"]), "Images")

      view |> form("#files-search", %{q: "cat", type: ""}) |> render_submit()
      assert_patch(view, ~p"/files?q=cat")

      sha = Base.encode16(cat.sha256, case: :lower)
      assert has_element?(view, ~s(#files-results a[href="/b/#{cat.txid}"]), "cat.png")
      assert has_element?(view, ~s(#files-results a[href="/c/#{sha}"]), "c://")
      assert has_element?(view, "#files-results", "641,000")

      assert has_element?(
               view,
               ~s(#files-results a[href="/content/bcat/#{bcat.txid}"]),
               "concat.mp4"
             )

      assert has_element?(view, "#files-results", "BCat, 3 chunks")
      refute has_element?(view, "#files-results", "dog.txt")
      refute has_element?(view, "#files")
    end

    test "filters by type, and pages with a cursor", %{conn: conn} do
      for i <- 1..26,
          do: put(%{filename: "img#{i}.png", media_type: "image/png", block_height: i})

      put(%{filename: "notes.txt"})

      {:ok, view, _html} = live(conn, ~p"/files?type=image")
      assert view |> element("#files-results") |> render() =~ "img26.png"
      refute has_element?(view, "#files-results", "notes.txt")

      view |> element("#files-more") |> render_click()
      html = view |> element("#files-results") |> render()
      assert html =~ "img1.png"
      refute html =~ "img26.png"
      refute has_element?(view, "#files-more")

      view |> element("#files-clear") |> render_click()
      assert_patch(view, ~p"/files")
      assert has_element?(view, "#files-list")
    end

    test "nothing found says it's a miss in our index, never that no file exists", %{conn: conn} do
      put(%{filename: "a.txt", block_height: 640_000})

      {:ok, view, _html} = live(conn, ~p"/files?q=zebra&type=json")

      message = text(view, "#files-no-match")
      assert message =~ "No indexed file matches “zebra” of type json."
      assert message =~ "not proof the file doesn't exist"
    end

    test "coverage: files from the earliest block until the backfill covers block 0", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/files?q=x")

      assert text(view, "#files-coverage") =~
               "holds no files yet, until its backfill covers block 0"

      put(%{filename: "a.txt", block_height: 640_000})
      {:ok, view, _html} = live(conn, ~p"/files?q=x")

      assert text(view, "#files-coverage") =~
               "holds files from block 640,000 on, until its backfill covers block 0"
    end

    test "coverage: blocks 0 to N once the backfill reaches block 0", %{conn: conn} do
      table = Bitblocks.SyncProgress
      empty = Bitblocks.SyncProgress.empty_snapshot()
      :ets.insert(table, {:snapshot, put_in(empty, [:overview, :complete_through], 1_000)})
      on_exit(fn -> :ets.insert(table, {:snapshot, empty}) end)

      Bitblocks.Repo.insert!(%Bitblocks.Derivations.Run{
        derivation: "c_files",
        version: CFiles.version(),
        from_height: 0,
        to_height: 900,
        applied: true,
        outcome: "ok",
        started_at: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, ~p"/files?q=x")
      assert text(view, "#files-coverage") =~ "B:// and BCat files in blocks 0 to 900."
    end

    test "a C:// address the index holds goes straight to the file", %{conn: conn} do
      row = put(%{filename: "a.txt", content: "bytes"})
      sha = Base.encode16(row.sha256, case: :lower)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/files?q=#{sha}")
      assert to == "/c/#{sha}"

      {:ok, view, _html} = live(conn, ~p"/files")
      view |> form("#files-search", %{q: "c://" <> String.upcase(sha)}) |> render_submit()
      assert_redirect(view, "/c/#{sha}")
    end

    test "a C:// address the index doesn't hold stays here and says so", %{conn: conn} do
      sha = String.duplicate("ab", 32)
      {:ok, view, _html} = live(conn, ~p"/files?q=#{sha}")

      message = text(view, "#files-address-miss")
      assert message =~ "No file in the C:// index has the address"
      assert message =~ sha
      assert message =~ "not proof the file doesn't exist"
      assert has_element?(view, "#files-coverage")
    end

    test "an unknown type or a garbled cursor is ignored", %{conn: conn} do
      put(%{filename: "a.txt"})

      {:ok, view, _html} = live(conn, ~p"/files?type=pdf")
      assert has_element?(view, "#files-list")

      {:ok, view, _html} = live(conn, ~p"/files?q=a&cursor=nope")
      assert has_element?(view, "#files-results", "a.txt")
    end
  end
end
