defmodule Bitblocks.UsageTest do
  @moduledoc """
  Usage metering (https://github.com/afomi/bitblocks/issues/61): requests,
  response bytes, database time and upstream calls by caller and endpoint
  class, rolled up hourly, charging nobody.
  """
  # async: false: the counters' ETS table is global.
  use Bitblocks.DataCase, async: false

  alias Bitblocks.{ApiKeys, Repo, Usage}
  alias Bitblocks.Accounts.User
  alias Bitblocks.Usage.Rollup

  defp keyed_conn(key_id, path \\ "/api/v1/blocks") do
    Plug.Test.conn(:get, path)
    |> Plug.Conn.assign(:api_key, %{id: key_id})
  end

  # Runs one metered request in this process: begin, work, before_send.
  defp metered(conn, status, body, work \\ fn -> :ok end) do
    Usage.begin_request()
    work.()
    %{conn | status: status, resp_body: body, state: :set} |> Usage.finish_request()
  end

  defp unique_id, do: System.unique_integer([:positive])

  describe "endpoint_class/1" do
    test "names each class from the path" do
      assert Usage.endpoint_class("/api/v1/blocks") == "read"
      assert Usage.endpoint_class("/api/v1/txs/abc") == "read"
      assert Usage.endpoint_class("/bitcom.json") == "read"
      assert Usage.endpoint_class("/api/v1/txs/abc/raw") == "raw_export"
      assert Usage.endpoint_class("/api/v1/types/export.csv") == "raw_export"
      assert Usage.endpoint_class("/api/v1/projections/7/txs") == "raw_export"
      assert Usage.endpoint_class("/content/abc_0") == "raw_export"
      assert Usage.endpoint_class("/b/abc") == "raw_export"
      assert Usage.endpoint_class("/api/v1/stream/blocks") == "stream"
      assert Usage.endpoint_class("/api/v1/projections/7/follow") == "stream"
      assert Usage.endpoint_class("/api/v1/txs/abc/proof") == "proof"
      assert Usage.endpoint_class("/api/v1/txs/abc/beef") == "proof"
      assert Usage.endpoint_class("/api/v1/beef/verify") == "proof"
      assert Usage.endpoint_class("/api/v1/ops/sync") == "ops"
      assert Usage.endpoint_class("/blocks/1") == "page"
      assert Usage.endpoint_class("/") == "page"
    end
  end

  describe "upstream/1" do
    setup do
      previous = Application.get_env(:bitblocks, :rest_url)
      Application.put_env(:bitblocks, :rest_url, "http://node.example:8332")
      on_exit(fn -> Application.put_env(:bitblocks, :rest_url, previous) end)
    end

    test "classes a host as our node, WhatsOnChain, CoinGecko or other" do
      assert Usage.upstream("node.example") == :node_calls
      assert Usage.upstream("api.whatsonchain.com") == :woc_calls
      assert Usage.upstream("api.coingecko.com") == :coingecko_calls
      assert Usage.upstream("s3.example") == :other_calls
      assert Usage.upstream(nil) == :other_calls
    end
  end

  describe "a metered request" do
    test "counts requests, bytes, 4xx, DB queries and upstream calls under its key" do
      id = unique_id()

      metered(keyed_conn(id), 200, ~s({"data":[]}), fn ->
        Repo.query!("SELECT 1")
        Repo.query!("SELECT 2")

        :telemetry.execute([:finch, :request, :stop], %{duration: 1_000}, %{
          request: %{host: "api.whatsonchain.com"}
        })
      end)

      metered(keyed_conn(id), 404, "nope")

      %{totals: t, by_class: [read]} = Usage.caller_usage({"key", to_string(id)})

      assert t.requests == 2
      assert t.status_4xx == 1
      assert t.status_5xx == 0
      assert t.response_bytes == byte_size(~s({"data":[]})) + 4
      assert t.db_queries >= 2
      assert t.db_us > 0
      assert t.woc_calls == 1
      assert t.node_calls == 0
      assert read.class == "read"
      assert read.per_request.response_bytes == div(t.response_bytes, 2)
    end

    test "a stream keeps counting its chunks after the headers go" do
      id = unique_id()
      conn = keyed_conn(id, "/api/v1/stream/blocks")

      Usage.begin_request()
      %{conn | status: 200, state: :set_chunked} |> Usage.finish_request()
      Usage.add_bytes("event: block_updated\n\n")
      Usage.add_bytes(10)

      %{by_class: [stream]} = Usage.caller_usage({"key", to_string(id)})
      assert stream.class == "stream"
      assert stream.requests == 1
      assert stream.response_bytes == byte_size("event: block_updated\n\n") + 10
    end

    test "a process that isn't a metered request counts nothing" do
      Process.delete(:bitblocks_usage)
      assert Usage.add_bytes(100) == :ok
      assert Usage.handle_event([:bitblocks, :repo, :query], %{total_time: 5}, %{}, nil) == :ok
    end

    test "names the caller from what the rate limiter assigned" do
      conn = Plug.Test.conn(:get, "/")
      assert Usage.caller(conn) == {"anonymous", ""}
      assert Usage.caller(Plug.Conn.assign(conn, :ai_crawler, "gptbot")) == {"crawler", "gptbot"}

      signed_in =
        conn |> Plug.Conn.assign(:caller_user_id, 7) |> Plug.Conn.assign(:caller_tier, :signed_in)

      assert Usage.caller(signed_in) == {"user", "7"}
      assert Usage.caller(Plug.Conn.assign(conn, :caller_user_id, 7)) == {"anonymous", ""}
      assert Usage.caller(Plug.Conn.assign(signed_in, :api_key, %{id: 3})) == {"key", "3"}
    end
  end

  describe "flush/0 and report/1" do
    test "flushes into hourly rollups, adding to what is there, and reports by class and caller" do
      {:ok, key, _token} = ApiKeys.create("usage-test", 60)
      user = Repo.insert!(%User{github_id: unique_id(), login: "meter#{unique_id()}"})

      user_conn =
        Plug.Test.conn(:get, "/api/v1/txs/abc/raw")
        |> Plug.Conn.assign(:caller_user_id, user.id)
        |> Plug.Conn.assign(:caller_tier, :signed_in)

      metered(keyed_conn(key.id), 200, "12345")
      assert {:ok, rows} = Usage.flush()
      assert rows >= 1

      metered(keyed_conn(key.id), 200, "12345")
      metered(user_conn, 200, String.duplicate("x", 1_000))
      assert {:ok, _} = Usage.flush()

      row = Repo.get_by!(Rollup, caller_kind: "key", caller_id: to_string(key.id))
      assert row.requests == 2
      assert row.response_bytes == 10
      assert row.endpoint_class == "read"
      assert DateTime.to_unix(row.hour) |> rem(3600) == 0

      report = Usage.report(hours: 24)
      read = Enum.find(report.by_class, &(&1.class == "read"))
      raw = Enum.find(report.by_class, &(&1.class == "raw_export"))
      assert read.requests >= 2
      assert raw.requests >= 1

      keyed = Enum.find(report.by_caller, &(&1.caller_id == to_string(key.id)))
      assert keyed.label == "usage-test (#{key.prefix})"
      assert keyed.totals.requests == 2

      person =
        Enum.find(
          report.by_caller,
          &(&1.caller_id == to_string(user.id) and &1.caller_kind == "user")
        )

      assert person.label == "@" <> user.login
      assert [%{class: "raw_export", requests: 1}] = person.by_class
    end

    test "a failed write puts the counts back for the next flush" do
      id = unique_id()
      metered(keyed_conn(id), 200, "abc")
      # A row the table refuses (endpoint_class is NOT NULL) fails its chunk.
      bad =
        {{div(System.os_time(:second), 3600) * 3600, "key", "bad", nil}, 1, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0}

      :ets.insert(:usage_meter, bad)

      assert {:error, _reason} = Usage.flush()

      pattern = {{:_, "key", to_string(id), :_}, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_}
      assert [row] = :ets.match_object(:usage_meter, pattern)
      # requests and response_bytes, kept for the next flush
      assert elem(row, 1) == 1
      assert elem(row, 4) == 3

      :ets.match_delete(
        :usage_meter,
        {{:_, "key", "bad", :_}, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_}
      )
    end

    test "a window with nothing in it reports zeros" do
      report = Usage.report(hours: 1)
      assert is_integer(report.totals.requests)
      assert report.hours == 1
      assert Usage.report(hours: 100_000).hours == 24 * 90
    end
  end

  test "format_bytes/1" do
    assert Usage.format_bytes(999) == "999 B"
    assert Usage.format_bytes(1_500) == "1.5 KB"
    assert Usage.format_bytes(2_000_000_000) == "2.0 GB"
  end
end
