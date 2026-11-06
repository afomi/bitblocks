defmodule Bitblocks.Ops.ScrubTest do
  # What an operator key can read must carry no credentials, node addresses,
  # environment values or Bitcoin addresses (#50).
  use ExUnit.Case, async: false

  alias Bitblocks.Ops.Scrub

  test "nil stays nil, and a plain reason reads the same" do
    assert Scrub.line(nil) == nil
    assert Scrub.line("{:http_error, 503}") == "{:http_error, 503}"
    assert Scrub.line({:http_error, 503}) == "{:http_error, 503}"
  end

  test "leaves block hashes, heights, times and module names alone" do
    hash = "000000000000000001f3e4b9c9e7a5a2d6d3b6a8e4f4e6a4b1c2d3e4f5a6b7c8"
    line = "FetchTxs block=957301 hash=#{hash} at 12:34:56 in Bitblocks.Chain.RawBlock"
    assert Scrub.line(line) == line
  end

  test "removes URLs whole, with their credentials" do
    for url <- [
          "http://rpcuser:hunter2@10.0.1.5:8332/",
          "postgres://bitblocks:s3cret@db.internal:5432/bitblocks",
          "https://bsv-rpc.example.com/rest"
        ] do
      scrubbed = Scrub.line("failed to reach #{url} after 3 tries")
      assert scrubbed == "failed to reach [url] after 3 tries"
    end
  end

  test "removes IP addresses in every form they turn up in" do
    assert Scrub.line("connect 10.0.1.5:8332 refused") == "connect [ip] refused"
    assert Scrub.line("peer {10, 0, 1, 5} closed") == "peer [ip] closed"
    assert Scrub.line("peer 2001:db8::8a2e:370:7334 closed") == "peer [ip] closed"
    assert Scrub.line("peer ::1 closed") == "peer [ip] closed"
    assert Scrub.line("peer 2001:0db8:0000:0000:0000:8a2e:0370:7334") == "peer [ip]"
  end

  test "removes node names, emails and host names" do
    assert Scrub.line("node bitblocks@10.0.1.5 down") == "node [host] down"
    assert Scrub.line("mail to ryan@example.com failed") == "mail to [host] failed"
    assert Scrub.line("nxdomain ip-10-0-1-5.ec2.internal") == "nxdomain [host]"
    assert Scrub.line("nxdomain db.us-east-1.rds.amazonaws.com:5432") == "nxdomain [host]"
  end

  test "removes Bitcoin addresses, and keeps a 64-character txid" do
    assert Scrub.line("to 1BAPSuaPnfGnSBM3GLV9yhxUdYe4vGbdMT") == "to [address]"
    assert Scrub.line("to 3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy") == "to [address]"
  end

  test "removes keys and credentials by shape" do
    token = "bbk_" <> String.duplicate("aZ0-_", 8)
    assert Scrub.line("key #{token} refused") == "key [key] refused"
    assert Scrub.line("Authorization: Bearer abc.def") =~ "[redacted]"
    refute Scrub.line("Authorization: Bearer abc.def") =~ "abc.def"
    assert Scrub.line("password=hunter2 rejected") == "password=[redacted] rejected"
    assert Scrub.line(~s(%{"secret" => "hunter2"})) =~ "[redacted]"
    refute Scrub.line(~s(%{"secret" => "hunter2"})) =~ "hunter2"
    assert Scrub.line(~s(token: "hunter2")) == "token=[redacted]"
  end

  describe "known values" do
    setup do
      keys = [:rpc_user, :rpc_password, :bitcoin_url]
      previous = Map.new(keys, &{&1, Application.get_env(:bitblocks, &1)})
      System.put_env("OPS_SCRUB_TEST_VALUE", "an-env-value-with-no-shape")

      on_exit(fn ->
        System.delete_env("OPS_SCRUB_TEST_VALUE")

        Enum.each(previous, fn
          {key, nil} -> Application.delete_env(:bitblocks, key)
          {key, value} -> Application.put_env(:bitblocks, key, value)
        end)
      end)
    end

    test "removes the exact RPC credentials, whatever surrounds them" do
      Application.put_env(:bitblocks, :rpc_user, "nodeoperator")
      Application.put_env(:bitblocks, :rpc_password, "correct-horse-battery")

      line = Scrub.line("user nodeoperator with correct-horse-battery was refused")
      assert line == "user [redacted] with [redacted] was refused"
    end

    test "removes the configured node URL, even with no scheme to match" do
      Application.put_env(:bitblocks, :bitcoin_url, "nodehost.private:8332")
      assert Scrub.line("cannot reach nodehost.private:8332") == "cannot reach [redacted]"
    end

    test "removes any environment value" do
      assert Scrub.line("saw an-env-value-with-no-shape here") == "saw [redacted] here"
    end
  end

  test "folds a long, multi-line reason into one bounded line" do
    line = Scrub.line("first\n  second\n" <> String.duplicate("x", 9_000))
    assert String.starts_with?(line, "first second ")
    refute line =~ "\n"
    assert String.length(line) == 500
  end
end
