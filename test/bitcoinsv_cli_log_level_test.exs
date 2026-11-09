defmodule BitcoinsvCliLogLevelTest do
  # A node that is down or restarting is expected now and then: each call logs
  # a warning, and Bitblocks.Ops emails "node unreachable" while it lasts, so the
  # error log (and the alarm reading it) stays for real faults.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    saved =
      for k <- [:rpc_url, :bitcoin_url, :rpc_user, :rpc_password],
          do: {k, Application.get_env(:bitblocks, k)}

    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    Application.put_env(:bitblocks, :rpc_url, nil)
    Application.put_env(:bitblocks, :bitcoin_url, "http://127.0.0.1:#{port}")
    Application.put_env(:bitblocks, :rpc_user, "u")
    Application.put_env(:bitblocks, :rpc_password, "p")

    on_exit(fn ->
      for {k, v} <- saved, do: Application.put_env(:bitblocks, k, v)
    end)
  end

  test "a refused connection is a warning, not an error" do
    errors =
      capture_log([level: :error], fn ->
        assert {:error, {:connection_error, :econnrefused}} = BitcoinsvCli.getblockchaininfo()
      end)

    refute errors =~ "Bitcoin RPC connection error"

    warnings =
      capture_log([level: :warning], fn -> BitcoinsvCli.getblockchaininfo() end)

    assert warnings =~ "Bitcoin RPC connection error"
  end
end
