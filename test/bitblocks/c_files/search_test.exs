defmodule Bitblocks.CFiles.SearchTest do
  # Find a file in the C:// index (https://github.com/afomi/bitblocks/issues/175).
  use Bitblocks.DataCase, async: true

  alias Bitblocks.CFiles
  alias Bitblocks.CFiles.Search

  defp put(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    content = Map.get(attrs, :content, attrs[:filename] || "x")

    row =
      %{
        sha256: :crypto.hash(:sha256, content),
        txid: attrs[:txid] || Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        vout: 0,
        block_height: Map.get(attrs, :block_height, 600_000),
        kind: Map.get(attrs, :kind, "b"),
        chunks: nil,
        media_type: Map.get(attrs, :media_type, "text/plain"),
        encoding: nil,
        filename: attrs[:filename],
        size: byte_size(content),
        version: CFiles.version(),
        inserted_at: now,
        updated_at: now
      }

    1 = CFiles.write([row])
    row
  end

  defp names({:ok, %{files: files}}), do: Enum.map(files, & &1.filename)

  describe "by name" do
    test "matches part of a filename, any case, newest block first" do
      put(%{filename: "Cat.png", media_type: "image/png", block_height: 600_000})
      put(%{filename: "concatenate.txt", block_height: 610_000})
      put(%{filename: "dog.png", media_type: "image/png"})

      assert names(Search.search(q: "cat")) == ["concatenate.txt", "Cat.png"]
    end

    test "% and _ match themselves, not any character" do
      put(%{filename: "100%.txt"})
      put(%{filename: "1000.txt"})
      put(%{filename: "a_b.txt"})
      put(%{filename: "axb.txt"})

      assert names(Search.search(q: "0%")) == ["100%.txt"]
      assert names(Search.search(q: "a_b")) == ["a_b.txt"]
    end

    test "a blank q lists everything; a long one is cut to the bound" do
      put(%{filename: "one"})
      assert names(Search.search(q: "   ")) == ["one"]

      long = String.duplicate("a", 500)
      assert String.length(Search.normalize_query(long)) == Search.max_query()
    end
  end

  describe "by type" do
    setup do
      put(%{filename: "a.png", media_type: "image/png"})
      put(%{filename: "b.txt", media_type: "text/plain"})
      put(%{filename: "c.md", media_type: "text/markdown; charset=utf-8"})
      put(%{filename: "d.json", media_type: "application/json"})
      put(%{filename: "e.html", media_type: "Text/HTML"})
      put(%{filename: "f.mp4", media_type: "video/mp4"})
      put(%{filename: "g", media_type: nil})
      :ok
    end

    test "each type reads the media type before any parameters, in any case" do
      sorted = fn type -> Search.search(type: type) |> names() |> Enum.sort() end

      assert sorted.("image") == ["a.png"]
      assert sorted.("text") == ["b.txt", "c.md"]
      assert sorted.("json") == ["d.json"]
      assert sorted.("html") == ["e.html"]
      assert sorted.("other") == ["f.mp4", "g"]
    end

    test "joins a name" do
      assert names(Search.search(q: "a", type: "image")) == ["a.png"]
    end

    test "an unknown type is refused" do
      assert Search.search(type: "pdf") == {:error, :invalid_type}
    end
  end

  describe "by C:// address" do
    test "a 64-hex q, with or without c://, matches the sha256 exactly" do
      row = put(%{filename: "x.txt", content: "the bytes"})
      put(%{filename: "y.txt"})
      hex = Base.encode16(row.sha256, case: :lower)

      assert Search.classify(hex) == {:address, row.sha256}
      assert Search.classify("c://" <> String.upcase(hex)) == {:address, row.sha256}
      assert Search.classify("x.txt") == {:name, "x.txt"}
      assert names(Search.search(q: hex)) == ["x.txt"]
    end
  end

  describe "the cursor" do
    test "pages newest block first without repeating, unknown blocks last" do
      for h <- 1..5, do: put(%{filename: "f#{h}", block_height: h})
      put(%{filename: "f-unknown", block_height: nil})

      {:ok, p1} = Search.search(per_page: 4)
      assert Enum.map(p1.files, & &1.filename) == ["f5", "f4", "f3", "f2"]
      assert p1.next_cursor

      {:ok, p2} = Search.search(per_page: 4, cursor: p1.next_cursor)
      assert Enum.map(p2.files, & &1.filename) == ["f1", "f-unknown"]
      assert p2.next_cursor == nil
    end

    test "a garbled cursor is refused" do
      assert Search.search(cursor: "nope") == {:error, :invalid_cursor}
      assert Search.search(cursor: "1:0") == {:error, :invalid_cursor}
      assert Search.parse_cursor("-1:7") == {:ok, {-1, 7}}
    end
  end

  test "a page is at most 100 files, however many are asked for" do
    for i <- 1..101, do: put(%{filename: "f#{i}"})

    {:ok, page} = Search.search(per_page: 1_000)
    assert length(page.files) == 100
    assert page.next_cursor

    {:ok, rest} = Search.search(per_page: 1_000, cursor: page.next_cursor)
    assert length(rest.files) == 1
    assert rest.next_cursor == nil
  end

  test "the plan reads c_files only, never transactions" do
    for {type, q} <- [{nil, "cat"}, {"image", nil}, {"other", "x"}] do
      {:ok, query} =
        Search.query(q: q, type: type, cursor: "600000:1")

      plan = Repo.explain(:all, from(c in query, limit: 26))

      assert plan =~ "c_files"
      refute plan =~ "transactions"
    end
  end

  test "coverage names the earliest indexed block until the backfill covers block 0" do
    assert %{indexed_through_height: nil, earliest_indexed_height: nil} = Search.coverage()

    put(%{filename: "a", block_height: 640_000})
    put(%{filename: "b", block_height: 650_000})

    assert %{indexed_through_height: nil, earliest_indexed_height: 640_000} = Search.coverage()
  end
end
