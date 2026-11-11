defmodule Bitblocks.HTTPTest do
  # Outbound HTTP on Finch (#65): any status comes back as a response, a
  # transport failure as its bare reason, a body past :max_body_length is
  # refused, and ExAws gets the shape its behaviour asks for.
  use ExUnit.Case, async: true

  alias Bitblocks.HTTP

  defmodule Origin do
    @behaviour Plug

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/bytes/" <> n} = conn, _opts) do
      Plug.Conn.send_resp(conn, 200, :binary.copy("x", String.to_integer(n)))
    end

    def call(%Plug.Conn{request_path: "/echo"} = conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_header("x-method", conn.method)
      |> Plug.Conn.put_resp_header(
        "x-auth",
        Plug.Conn.get_req_header(conn, "authorization") |> Enum.join()
      )
      |> Plug.Conn.send_resp(201, body)
    end

    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 429, "slow down")
  end

  setup do
    server = start_supervised!({Bandit, plug: Origin, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  test "a POST carries its body and headers; the status comes back as is", %{base: base} do
    assert {:ok, %Finch.Response{status: 201, body: "hello", headers: headers}} =
             HTTP.post(base <> "/echo", "hello", [{"authorization", "Basic abc"}])

    assert {"x-method", "POST"} in headers
    assert {"x-auth", "Basic abc"} in headers

    assert {:ok, %Finch.Response{status: 429, body: "slow down"}} = HTTP.get(base <> "/other")
  end

  test "a body within :max_body_length is read whole; one past it is refused", %{base: base} do
    assert {:ok, %Finch.Response{status: 200, body: body}} =
             HTTP.get(base <> "/bytes/200000", [], max_body_length: 200_000)

    assert byte_size(body) == 200_000

    assert {:error, :body_too_large} =
             HTTP.get(base <> "/bytes/200001", [], max_body_length: 200_000)
  end

  test "a refused connection and a bad URL are bare reasons" do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    assert {:error, :econnrefused} = HTTP.get("http://127.0.0.1:#{port}/")

    assert {:error, :econnrefused} =
             HTTP.get("http://127.0.0.1:#{port}/", [], max_body_length: 10)

    assert {:error, :invalid_url} = HTTP.get("not a url")
  end

  test "ExAws gets status_code, headers and body, and errors as %{reason: _}", %{base: base} do
    assert {:ok, %{status_code: 201, body: "put", headers: headers}} =
             Bitblocks.HTTP.ExAwsClient.request(:put, base <> "/echo", "put", [], [])

    assert {"x-method", "PUT"} in headers

    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    assert {:error, %{reason: :econnrefused}} =
             Bitblocks.HTTP.ExAwsClient.request(:get, "http://127.0.0.1:#{port}/", "", [], [])
  end

  test "ExAws is configured to use it" do
    assert Application.get_env(:ex_aws, :http_client) == Bitblocks.HTTP.ExAwsClient
  end
end
