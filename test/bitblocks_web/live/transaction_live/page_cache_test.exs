defmodule BitblocksWeb.TransactionLive.PageCacheTest do
  # One named cache for the VM.
  use ExUnit.Case, async: false

  alias BitblocksWeb.TransactionLive.PageCache

  setup do
    previous = Application.get_env(:bitblocks, PageCache)

    on_exit(fn ->
      Application.put_env(:bitblocks, PageCache, previous)
      PageCache.clear()
    end)

    PageCache.clear()
    :ok
  end

  defp configure(opts),
    do: Application.put_env(:bitblocks, PageCache, Keyword.merge([enabled: true], opts))

  defp value(bytes), do: %{blob: :binary.copy("x", bytes)}

  test "keeps and returns an entry" do
    configure([])

    assert PageCache.put("a", %{n: 1}) == :ok
    assert PageCache.stats().entries == 1
    assert PageCache.get("a") == {:ok, %{n: 1}}
    assert PageCache.get("b") == :miss
  end

  test "off, it keeps nothing" do
    configure(enabled: false)

    assert PageCache.put("a", %{n: 1}) == :skipped
    assert PageCache.get("a") == :miss
  end

  test "an entry over max_entry_bytes is not kept" do
    configure(max_entry_bytes: 1_000)

    assert PageCache.put("big", value(2_000)) == :skipped
    assert PageCache.stats().entries == 0
  end

  test "over max_bytes, the least recently read go first" do
    configure(max_bytes: 10_000, max_entry_bytes: 10_000)

    for key <- ~w(a b c), do: PageCache.put(key, value(3_000))
    assert PageCache.stats().entries == 3

    # a is read, so b is now the least recently read.
    Process.sleep(2)
    assert {:ok, _} = PageCache.get("a")

    PageCache.put("d", value(3_000))
    stats = PageCache.stats()

    assert stats.bytes <= 9_000
    assert PageCache.get("b") == :miss
    assert {:ok, _} = PageCache.get("a")
    assert {:ok, _} = PageCache.get("d")
  end

  test "an entry past its ttl is a miss" do
    configure(ttl_ms: 0)

    PageCache.put("a", %{n: 1})
    assert PageCache.stats().entries == 1
    assert PageCache.get("a") == :miss
  end

  test "deep_enough?/2 asks for min_depth blocks under the tip" do
    configure([])

    assert PageCache.deep_enough?(10, 110)
    refute PageCache.deep_enough?(10, 109)
    refute PageCache.deep_enough?(nil, 110)
    refute PageCache.deep_enough?(10, nil)
  end
end
