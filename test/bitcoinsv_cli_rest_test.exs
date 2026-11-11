defmodule BitcoinsvCliRestTest do
  # The node's REST block read on Finch (#65): the bytes come back whole, a
  # block past max_bytes is refused before it is held, and a missing block is
  # the node's status.
  use ExUnit.Case, async: false

  defmodule Node do
    @behaviour Plug

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/rest/block/" <> "known.bin"} = conn, _opts),
      do: Plug.Conn.send_resp(conn, 200, :binary.copy(<<0xAB>>, 1_000))

    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")
  end

  setup do
    server = start_supervised!({Bandit, plug: Node, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    saved = Application.get_env(:bitblocks, :rest_url)
    Application.put_env(:bitblocks, :rest_url, "http://127.0.0.1:#{port}")
    on_exit(fn -> Application.put_env(:bitblocks, :rest_url, saved) end)
  end

  test "reads a block within max_bytes and refuses one past it" do
    assert {:ok, bytes} = BitcoinsvCli.rest_block("known", 1_000)
    assert bytes == :binary.copy(<<0xAB>>, 1_000)

    assert {:error, {:connection_error, :body_too_large}} = BitcoinsvCli.rest_block("known", 999)
    assert {:error, {:http_error, 404}} = BitcoinsvCli.rest_block("unknown", 1_000)
  end
end
