defmodule Bitblocks.Protocol.RegistryCacheTest do
  # async: false — the cache is a shared named ETS table; refresh/clear here
  # must not race other tests that exercise protocol detection.
  use Bitblocks.DataCase, async: false

  alias Bitblocks.Protocol.{Handlers, RegistryCache}
  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.Script.OpReturn

  # Valid per Protocol.changeset's Bitcoin-address format (no 0/O/I/l).
  @fake_address "1CustomProtoTestAddr111111111"
  @fake_name "CustomProto"

  defp chunks(binaries) do
    OpReturn.parse_data(%BSV.Script{chunks: [:OP_RETURN | binaries]})
  end

  setup do
    RegistryCache.clear()
    on_exit(fn -> RegistryCache.clear() end)
    :ok
  end

  describe "empty cache (compile-time-only fallback)" do
    test "match_name/1 returns nil" do
      assert RegistryCache.match_name(@fake_address) == nil
      assert RegistryCache.match_name("") == nil
      assert RegistryCache.match_name(nil) == nil
    end

    test "detect_all/1 behavior is unchanged" do
      assert Handlers.detect_all(chunks([@fake_address, "payload"])) == []

      assert Handlers.detect_all(chunks(["19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", "content"])) ==
               ["B://"]

      assert Handlers.detect_all(chunks(["just some data"])) == []
    end
  end

  describe "refresh/0 loads DB-registered prefix protocols" do
    test "a registered protocol is picked up by detect_all/1" do
      assert {:ok, _protocol} =
               ProtocolRegistry.create_protocol(%{
                 address: @fake_address,
                 name: @fake_name,
                 description: "Test-only prefix protocol"
               })

      assert {:ok, count} = RegistryCache.refresh()
      assert count >= 1
      assert {@fake_address, @fake_name} in RegistryCache.entries()

      assert Handlers.detect_all(chunks([@fake_address, "payload"])) == [@fake_name]
    end

    test "prefix semantics: first chunk starting with the address matches" do
      {:ok, _} = ProtocolRegistry.create_protocol(%{address: @fake_address, name: @fake_name})
      {:ok, _} = RegistryCache.refresh()

      assert RegistryCache.match_name(@fake_address <> "trailing") == @fake_name
      assert Handlers.detect_all(chunks([@fake_address <> "v2", "payload"])) == [@fake_name]
    end

    test "compile-time segment matches still win; cache only fills unmatched segments" do
      {:ok, _} = ProtocolRegistry.create_protocol(%{address: @fake_address, name: @fake_name})
      {:ok, _} = RegistryCache.refresh()

      piped =
        chunks([
          "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut",
          "post content",
          "|",
          @fake_address,
          "payload"
        ])

      assert Handlers.detect_all(piped) == ["B://", @fake_name]
    end

    test "rows named after a compile-time handler are excluded (no shadowing)" do
      shadow_address = "1ShadowMapAddr111111111111111"

      {:ok, _} = ProtocolRegistry.create_protocol(%{address: shadow_address, name: "MAP"})
      {:ok, _} = RegistryCache.refresh()

      refute {shadow_address, "MAP"} in RegistryCache.entries()
      assert Handlers.detect_all(chunks([shadow_address, "payload"])) == []
    end

    test "clear/0 empties the cache and detection falls back" do
      {:ok, _} = ProtocolRegistry.create_protocol(%{address: @fake_address, name: @fake_name})
      {:ok, _} = RegistryCache.refresh()
      assert Handlers.detect_all(chunks([@fake_address, "payload"])) == [@fake_name]

      :ok = RegistryCache.clear()

      assert RegistryCache.entries() == []
      assert Handlers.detect_all(chunks([@fake_address, "payload"])) == []
    end
  end
end
