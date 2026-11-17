defmodule BitblocksWeb.MalformedRequestLogTest do
  @moduledoc """
  A scanner's malformed request line is a client mistake, not an app error,
  so it logs at warning and stays out of the error digest; real errors still
  log at error (https://github.com/afomi/bitblocks/issues/90).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bitblocks.LogFilters

  defp event(level, reason) do
    %{
      level: level,
      msg: {:string, "boom"},
      meta: %{domain: [:elixir, :bandit], crash_reason: {reason, []}}
    }
  end

  test "a malformed request line from a client is lowered to a warning" do
    error = %Bandit.HTTPError{message: "Request line HTTP error: \"GET /assets/)}})}\""}

    assert %{level: :warning} = LogFilters.malformed_request(event(:error, error), [])
  end

  test "real errors keep their level" do
    assert LogFilters.malformed_request(event(:error, %RuntimeError{message: "x"}), []) == :ignore

    other_http = %Bandit.HTTPError{message: "Body read timeout", plug_status: :request_timeout}
    assert LogFilters.malformed_request(event(:error, other_http), []) == :ignore

    assert LogFilters.malformed_request(%{level: :error, msg: {:string, "x"}, meta: %{}}, []) ==
             :ignore
  end

  test "the running server logs a scanner's malformed request line as a warning" do
    port = Application.fetch_env!(:bitblocks, BitblocksWeb.Endpoint)[:http][:port]

    log =
      capture_log([level: :warning], fn ->
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

        :ok =
          :gen_tcp.send(
            socket,
            "GET /assets/)}})}send(i){typeof i!=\"string\"&&(i=wv(i)) HTTP/1.1\r\nHost: localhost\r\n\r\n"
          )

        {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
        assert response =~ "400"
        :gen_tcp.close(socket)
        Process.sleep(200)
      end)

    assert log =~ "Request line HTTP error"
    assert log =~ "[warning]"
    refute log =~ "[error]"
  end
end
