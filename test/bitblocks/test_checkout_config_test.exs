defmodule Bitblocks.TestCheckoutConfigTest do
  # Per-checkout test database and port (#85): config/test_checkout.exs.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  setup_all do
    {fun, _} = Code.eval_file("test_checkout.exs", Path.join(@root, "config"))
    %{checkout: fun}
  end

  test "the same path always gives the same partition and port", %{checkout: f} do
    assert f.("/tmp/a/bitblocks", %{}) == f.("/tmp/a/bitblocks", %{})
    assert %{partition: "_" <> hex, port: port} = f.("/tmp/a/bitblocks", %{})
    assert hex =~ ~r/\A[0-9a-f]{8}\z/
    assert port in 40_000..48_999
  end

  test "different checkouts get different partitions and ports", %{checkout: f} do
    a = f.("/tmp/a/bitblocks", %{})
    b = f.("/tmp/b/bitblocks", %{})
    assert a.partition != b.partition
    assert a.port != b.port
  end

  test "MIX_TEST_PARTITION and TEST_PORT override", %{checkout: f} do
    env = %{"MIX_TEST_PARTITION" => "_x", "TEST_PORT" => "4641"}
    assert f.("/tmp/a/bitblocks", env) == %{partition: "_x", port: 4641}
  end

  test "this run uses its checkout's database and port", %{checkout: f} do
    expected = f.(@root, System.get_env())
    db = Application.fetch_env!(:bitblocks, Bitblocks.Repo)[:database]
    http = Application.fetch_env!(:bitblocks, BitblocksWeb.Endpoint)[:http]
    assert db == "bitblocks_test" <> expected.partition
    assert http[:port] == expected.port
  end
end
