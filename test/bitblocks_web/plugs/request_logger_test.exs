defmodule BitblocksWeb.Plugs.RequestLoggerTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias BitblocksWeb.Plugs.RequestLogger

  describe "redact_query_string/1" do
    test "redacts values for sensitive keys" do
      assert RequestLogger.redact_query_string("token=abc123") == "token=[REDACTED]"
      assert RequestLogger.redact_query_string("key=abc123") == "key=[REDACTED]"
      assert RequestLogger.redact_query_string("secret=abc123") == "secret=[REDACTED]"
      assert RequestLogger.redact_query_string("password=hunter2") == "password=[REDACTED]"
      assert RequestLogger.redact_query_string("auth=Bearer%20x") == "auth=[REDACTED]"
      assert RequestLogger.redact_query_string("api_key=abc123") == "api_key=[REDACTED]"
      assert RequestLogger.redact_query_string("apikey=abc123") == "apikey=[REDACTED]"
      assert RequestLogger.redact_query_string("signature=deadbeef") == "signature=[REDACTED]"
    end

    test "is case-insensitive" do
      assert RequestLogger.redact_query_string("Token=abc") == "Token=[REDACTED]"
      assert RequestLogger.redact_query_string("API_KEY=abc") == "API_KEY=[REDACTED]"
      assert RequestLogger.redact_query_string("PassWord=abc") == "PassWord=[REDACTED]"
    end

    test "matches sensitive words embedded in larger keys" do
      assert RequestLogger.redact_query_string("access_token=abc") == "access_token=[REDACTED]"
      assert RequestLogger.redact_query_string("auth_header=abc") == "auth_header=[REDACTED]"
    end

    test "leaves benign params untouched" do
      assert RequestLogger.redact_query_string("page=2&per_page=50") == "page=2&per_page=50"
      assert RequestLogger.redact_query_string("protocol=Twetch") == "protocol=Twetch"
    end

    test "redacts only the sensitive params in a mixed query string" do
      assert RequestLogger.redact_query_string("page=2&api_key=abc123&sort=desc") ==
               "page=2&api_key=[REDACTED]&sort=desc"
    end

    test "preserves empty strings and valueless params" do
      assert RequestLogger.redact_query_string("") == ""
      assert RequestLogger.redact_query_string("flag") == "flag"
      assert RequestLogger.redact_query_string("flag&token=x") == "flag&token=[REDACTED]"
    end

    test "redacts a sensitive param with an empty value" do
      assert RequestLogger.redact_query_string("token=") == "token=[REDACTED]"
    end

    test "matches URL-encoded keys" do
      # api%5Fkey decodes to api_key
      assert RequestLogger.redact_query_string("api%5Fkey=abc") == "api%5Fkey=[REDACTED]"
    end

    test "does not raise on malformed percent-encoding" do
      assert RequestLogger.redact_query_string("%zz=1&token=x") == "%zz=1&token=[REDACTED]"
    end
  end

  describe "call/2 logging integration" do
    test "a 4xx response with a sensitive query string does not crash the before_send hook" do
      conn =
        :get
        |> conn("/nonexistent?api_key=supersecret&page=1")
        |> RequestLogger.call([])
        |> send_resp(404, "not found")

      assert conn.status == 404
    end

    test "/sitemap.xml is not flagged as an XML probe" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :get |> conn("/sitemap.xml") |> RequestLogger.call([]) |> send_resp(200, "")
        end)

      refute log =~ "XML file probe"
    end

    test "other .xml paths are still flagged as an XML probe" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :get |> conn("/wp/feed.xml") |> RequestLogger.call([]) |> send_resp(404, "")
        end)

      assert log =~ "XML file probe"
    end
  end
end
