defmodule Bitblocks.Usage do
  @moduledoc """
  What each caller costs us, measured before any rate is set
  (https://github.com/afomi/bitblocks/issues/61, docs/USAGE_METERING.md).
  It charges nobody.

  For every HTTP request through the endpoint, by caller and endpoint class:
  requests, 4xx and 5xx answers, response bytes, time to the first byte,
  database time and queries, and outbound calls by upstream (our node's RPC
  and REST, WhatsOnChain, CoinGecko, anything else).

  ## How it is collected

    * `BitblocksWeb.Plugs.Meter` opens an accumulator in the request process's
      dictionary and registers a `before_send` callback.
    * Telemetry handlers (`attach/0`) add to it from the same process: Ecto's
      `[:bitblocks, :repo, :query]` (its `total_time`) and Finch's
      `[:finch, :request, :stop]`, classed by host (`upstream/1`).
    * At `before_send` the caller is known (`BitblocksWeb.Plugs.RateLimiter`
      set it, with no query), so the totals go into one ETS row per
      hour, caller and class, with `:ets.update_counter/4`.
      A stream keeps counting after that: each chunk's bytes and each query
      the stream runs go straight to its row.
    * `Bitblocks.Usage.Flusher` moves the rows into `usage_rollups` once a
      minute, adding to what other nodes wrote. No row per request.

  Work a request hands to another process (a `Task`, a GenServer call) is
  not attributed to it, and LiveView events over an open socket are not
  HTTP requests, so neither is counted (the rate limits don't count them
  either).

  Metering never blocks or fails a request: every step rescues and gives up
  quietly. `config :bitblocks, :usage_metering, false` turns it off.

  ## Callers

  `{"key", api_key_id}`, `{"user", user_id}` (signed in, admin or not),
  `{"crawler", family}` (an AI crawler without a key) or `{"anonymous", ""}`.
  An IP address is never stored.
  """

  import Ecto.Query
  require Logger

  alias Bitblocks.Repo
  alias Bitblocks.Usage.Rollup

  @table :usage_meter
  @pd :bitblocks_usage
  @counters Rollup.counters()
  @positions @counters |> Enum.with_index(2) |> Map.new()
  @blank List.to_tuple([nil | List.duplicate(0, length(@counters))])

  @classes ~w(read raw_export stream proof ops page)
  @max_hours 24 * 90

  @doc "The endpoint classes, in the order reports list them."
  def classes, do: @classes

  @doc "False when `config :bitblocks, :usage_metering, false`."
  def enabled?, do: Application.get_env(:bitblocks, :usage_metering, true) != false

  # ── The ETS table ──────────────────────────────────────────────────────

  @doc """
  Creates the counters table, owned by the calling process
  (`Bitblocks.Usage.Flusher`). A no-op when it already exists.
  """
  def create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── The request lifecycle ──────────────────────────────────────────────

  @doc "Opens a request's accumulator (`BitblocksWeb.Plugs.Meter`)."
  def begin_request do
    Process.put(@pd, {:pending, System.monotonic_time(:microsecond), %{}})
    :ok
  end

  @doc """
  The `before_send` callback: books the request under its caller and class.
  A chunked response keeps its row open for the stream's later chunks and queries.
  """
  def finish_request(%Plug.Conn{} = conn) do
    case Process.get(@pd) do
      {:pending, started, acc} ->
        {kind, id} = caller(conn)
        row = {kind, id, endpoint_class(conn.request_path)}

        bump(row, [
          {:requests, 1},
          {:status_4xx, if(conn.status in 400..499, do: 1, else: 0)},
          {:status_5xx, if(conn.status in 500..599, do: 1, else: 0)},
          {:response_bytes, body_bytes(conn)},
          {:duration_us, System.monotonic_time(:microsecond) - started}
          | Map.to_list(acc)
        ])

        if conn.state == :set_chunked,
          do: Process.put(@pd, {:streaming, row}),
          else: Process.delete(@pd)

      _ ->
        :ok
    end

    conn
  rescue
    error ->
      Process.delete(@pd)
      Logger.debug("Usage metering skipped a request: #{Exception.message(error)}")
      conn
  end

  @doc "Adds bytes a stream sent after its headers (`BitblocksWeb.Api.StreamController`)."
  def add_bytes(bytes) when is_integer(bytes), do: add([{:response_bytes, bytes}])

  def add_bytes(data) do
    add([{:response_bytes, IO.iodata_length(data)}])
  rescue
    _ -> :ok
  end

  @doc "Who is asking, as the rate limiter decided it. No query."
  def caller(%Plug.Conn{assigns: assigns}) do
    cond do
      match?(%{id: _}, assigns[:api_key]) ->
        {"key", to_string(assigns.api_key.id)}

      assigns[:ai_crawler] ->
        {"crawler", to_string(assigns.ai_crawler)}

      assigns[:caller_user_id] && assigns[:caller_tier] in [:admin, :signed_in] ->
        {"user", to_string(assigns.caller_user_id)}

      true ->
        {"anonymous", ""}
    end
  end

  @doc """
  The endpoint class of a request path:

    * `stream` - SSE: `/api/v1/stream/*` and a projection's `/follow`
    * `proof` - `/api/v1/txs/:txid/proof`, `/beef` and `POST /api/v1/beef/verify`
    * `raw_export` - a tx's raw bytes, `/content/*`, `/b/:txid`, the types
      export, a registry snapshot's bytes, a projection's hydrate pages
    * `ops` - `/api/v1/ops/*`
    * `read` - any other `/api/*`, and `/bitcom.json`
    * `page` - everything else (HTML pages, LiveViews' first render)
  """
  def endpoint_class(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["api", "v1", "ops" | _] -> "ops"
      ["api", "v1", "stream" | _] -> "stream"
      ["api", "v1", "projections", _, "follow"] -> "stream"
      ["api", "v1", "txs", _, proof] when proof in ["proof", "beef"] -> "proof"
      ["api", "v1", "beef", "verify"] -> "proof"
      ["api", "v1", "txs", _, "raw"] -> "raw_export"
      ["api", "v1", "woc", "tx", _, "hex"] -> "raw_export"
      ["api", "v1", "types", export] when export in ["export", "export.csv"] -> "raw_export"
      ["api", "v1", "bitcom", "snapshots", _] -> "raw_export"
      ["api", "v1", "projections", _, page] when page in ["txs", "commands"] -> "raw_export"
      ["content" | _] -> "raw_export"
      ["b", _] -> "raw_export"
      ["api" | _] -> "read"
      ["bitcom.json"] -> "read"
      _ -> "page"
    end
  end

  @doc "The counter an outbound call to `host` adds to."
  def upstream(host) when is_binary(host) do
    cond do
      host in node_hosts() -> :node_calls
      String.contains?(host, "whatsonchain") -> :woc_calls
      String.contains?(host, "coingecko") -> :coingecko_calls
      true -> :other_calls
    end
  end

  def upstream(_host), do: :other_calls

  defp node_hosts do
    [
      Bitblocks.Config.bitcoin_url(),
      Application.get_env(:bitblocks, :bitcoin_url),
      Application.get_env(:bitblocks, :rest_url)
    ]
    |> Enum.flat_map(fn
      url when is_binary(url) and url != "" -> [URI.parse(url).host]
      _ -> []
    end)
  end

  defp body_bytes(%Plug.Conn{resp_body: nil}), do: 0
  defp body_bytes(%Plug.Conn{resp_body: body}), do: IO.iodata_length(body)

  # ── Telemetry ──────────────────────────────────────────────────────────

  @handler_id "bitblocks-usage-meter"

  @doc "Attaches the query, outbound-call and exception handlers. Idempotent."
  def attach do
    events = [
      [:bitblocks, :repo, :query],
      [:finch, :request, :stop],
      [:phoenix, :router_dispatch, :exception]
    ]

    case :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    # Most processes aren't metered requests: one dictionary read and out.
    if Process.get(@pd), do: handle_metered(event, measurements, metadata)
    :ok
  rescue
    _ -> :ok
  end

  defp handle_metered([:bitblocks, :repo, :query], measurements, _metadata) do
    native =
      measurements[:total_time] ||
        (measurements[:queue_time] || 0) + (measurements[:query_time] || 0) +
          (measurements[:decode_time] || 0)

    add([{:db_us, to_us(native)}, {:db_queries, 1}])
  end

  defp handle_metered([:finch, :request, :stop], measurements, metadata) do
    host =
      case metadata[:request] do
        %{host: host} -> host
        _ -> nil
      end

    add([{upstream(host), 1}, {:upstream_us, to_us(measurements[:duration] || 0)}])
  end

  # A controller raised before sending: book it as a 5xx now, since the
  # error page may be rendered from a conn that never meets our callback.
  defp handle_metered([:phoenix, :router_dispatch, :exception], _measurements, %{conn: conn}) do
    case Process.get(@pd) do
      {:pending, _, _} -> finish_request(%{conn | status: 500, resp_body: nil, state: :set})
      _ -> :ok
    end
  end

  defp handle_metered(_event, _measurements, _metadata), do: :ok

  defp to_us(native), do: System.convert_time_unit(native, :native, :microsecond)

  defp add(incs) do
    case Process.get(@pd) do
      {:pending, started, acc} ->
        acc = Enum.reduce(incs, acc, fn {k, v}, acc -> Map.update(acc, k, v, &(&1 + v)) end)
        Process.put(@pd, {:pending, started, acc})

      {:streaming, row} ->
        bump(row, incs)

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp bump({kind, id, class}, incs) do
    key = {current_hour(), kind, id, class}

    ops =
      for {counter, value} <- incs, is_integer(value), value != 0 do
        {Map.fetch!(@positions, counter), value}
      end

    if ops != [], do: :ets.update_counter(@table, key, ops, put_elem(@blank, 0, key))
    :ok
  rescue
    # No table (the flusher isn't running): nothing to count into.
    ArgumentError -> :ok
  end

  defp current_hour, do: div(System.os_time(:second), 3600) * 3600

  # ── Flushing ───────────────────────────────────────────────────────────

  @doc """
  Moves this node's counters into `usage_rollups`, adding to each row.
  Each ETS row is taken (read and deleted at once), so a count made during
  the flush lands in a fresh row for the next one. On a failed write the
  counts go back into ETS. Returns `{:ok, rows}` or `{:error, reason}`.
  """
  def flush do
    taken =
      @table
      |> :ets.select([{{:"$1", :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_}, [], [:"$1"]}])
      |> Enum.flat_map(&:ets.take(@table, &1))

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Chunk by chunk, so a failed write puts back only what didn't land.
    taken
    |> Enum.chunk_every(500)
    |> Enum.reduce({:ok, 0}, fn
      chunk, {:ok, written} ->
        case write(chunk, now) do
          :ok -> {:ok, written + length(chunk)}
          {:error, _} = error -> restore_all(chunk, error)
        end

      chunk, {:error, _} = error ->
        restore_all(chunk, error)
    end)
  rescue
    ArgumentError -> {:ok, 0}
  end

  defp write(chunk, now) do
    chunk |> Enum.map(&to_row(&1, now)) |> upsert()
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "exit: #{inspect(reason)}"}
  end

  defp restore_all(chunk, error) do
    Enum.each(chunk, &restore/1)
    error
  end

  defp to_row(tuple, now) do
    {hour, kind, id, class} = elem(tuple, 0)

    counts =
      for {counter, pos} <- @positions, into: %{}, do: {counter, elem(tuple, pos - 1)}

    Map.merge(counts, %{
      hour: DateTime.from_unix!(hour),
      caller_kind: kind,
      caller_id: id,
      endpoint_class: class,
      inserted_at: now,
      updated_at: now
    })
  end

  defp restore(tuple) do
    key = elem(tuple, 0)

    ops =
      for {_counter, pos} <- @positions,
          elem(tuple, pos - 1) != 0,
          do: {pos, elem(tuple, pos - 1)}

    if ops != [], do: :ets.update_counter(@table, key, ops, put_elem(@blank, 0, key))
  rescue
    ArgumentError -> :ok
  end

  defp upsert(rows) do
    Repo.insert_all(Rollup, rows,
      conflict_target: [:hour, :caller_kind, :caller_id, :endpoint_class],
      on_conflict:
        from(r in Rollup,
          update: [
            inc: [
              requests: fragment("EXCLUDED.requests"),
              status_4xx: fragment("EXCLUDED.status_4xx"),
              status_5xx: fragment("EXCLUDED.status_5xx"),
              response_bytes: fragment("EXCLUDED.response_bytes"),
              duration_us: fragment("EXCLUDED.duration_us"),
              db_us: fragment("EXCLUDED.db_us"),
              db_queries: fragment("EXCLUDED.db_queries"),
              node_calls: fragment("EXCLUDED.node_calls"),
              woc_calls: fragment("EXCLUDED.woc_calls"),
              coingecko_calls: fragment("EXCLUDED.coingecko_calls"),
              other_calls: fragment("EXCLUDED.other_calls"),
              upstream_us: fragment("EXCLUDED.upstream_us")
            ],
            set: [updated_at: fragment("EXCLUDED.updated_at")]
          ]
        )
    )
  end

  # ── Reading ────────────────────────────────────────────────────────────

  @doc """
  Usage over the last `:hours` whole and current hours (default 24, at most
  90 days), from the flushed rollups:

    * `totals` - every counter summed, with per-request means (`per_request`)
    * `by_class` - one entry per endpoint class
    * `by_caller` - the top `:limit` callers (default 50) by requests, each
      named (`label`) and split by class

  Counts from the last minute on each node may not be flushed yet;
  `Release.usage_report/1` flushes this node first.
  """
  def report(opts \\ []) do
    {from, to, hours} = window(opts)
    limit = opts |> Keyword.get(:limit, 50) |> min(500) |> max(1)
    base = from(r in Rollup, where: r.hour >= ^from and r.hour < ^to)

    by_class =
      base
      |> group_by([r], r.endpoint_class)
      |> select(^sums())
      |> select_merge([r], %{class: r.endpoint_class})
      |> Repo.all()
      |> Enum.map(&with_means/1)
      |> Enum.sort_by(&class_order(&1.class))

    caller_rows =
      base
      |> group_by([r], [r.caller_kind, r.caller_id, r.endpoint_class])
      |> select(^sums())
      |> select_merge([r], %{kind: r.caller_kind, id: r.caller_id, class: r.endpoint_class})
      |> Repo.all()

    by_caller =
      caller_rows
      |> Enum.group_by(&{&1.kind, &1.id}, &Map.drop(&1, [:kind, :id]))
      |> Enum.map(fn {{kind, id}, rows} ->
        classes = rows |> Enum.map(&with_means/1) |> Enum.sort_by(&class_order(&1.class))

        %{
          caller_kind: kind,
          caller_id: id,
          totals:
            classes
            |> Enum.map(&Map.drop(&1, [:class, :per_request]))
            |> sum_maps()
            |> with_means(),
          by_class: classes
        }
      end)
      |> Enum.sort_by(& &1.totals.requests, :desc)
      |> Enum.take(limit)
      |> label_callers()

    totals =
      by_class
      |> Enum.map(&Map.drop(&1, [:class, :per_request]))
      |> sum_maps()
      |> with_means()

    %{
      from: from,
      to: to,
      hours: hours,
      totals: totals,
      by_class: by_class,
      by_caller: by_caller,
      callers: caller_rows |> Enum.map(&{&1.kind, &1.id}) |> Enum.uniq() |> length()
    }
  end

  @doc """
  One caller's usage over the last `hours` (default 24): flushed rollups plus
  this node's counts not yet flushed. For `GET /api/v1/usage`.
  """
  def caller_usage({kind, id}, opts \\ []) do
    {from, to, hours} = window(opts)

    flushed =
      from(r in Rollup,
        where: r.hour >= ^from and r.hour < ^to and r.caller_kind == ^kind and r.caller_id == ^id,
        group_by: r.endpoint_class
      )
      |> select(^sums())
      |> select_merge([r], %{class: r.endpoint_class})
      |> Repo.all()

    unflushed =
      try do
        @table
        |> :ets.match_object({{:_, kind, id, :_}, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_})
        |> Enum.map(fn tuple ->
          {_, _, _, class} = elem(tuple, 0)

          for(
            {counter, pos} <- @positions,
            into: %{class: class},
            do: {counter, elem(tuple, pos - 1)}
          )
        end)
      rescue
        ArgumentError -> []
      end

    by_class =
      (flushed ++ unflushed)
      |> Enum.group_by(& &1.class)
      |> Enum.map(fn {class, sums} ->
        sums |> sum_maps() |> with_means() |> Map.put(:class, class)
      end)
      |> Enum.sort_by(&class_order(&1.class))

    %{
      from: from,
      to: to,
      hours: hours,
      totals:
        by_class |> Enum.map(&Map.drop(&1, [:class, :per_request])) |> sum_maps() |> with_means(),
      by_class: by_class
    }
  end

  defp window(opts) do
    hours = opts |> Keyword.get(:hours, 24) |> min(@max_hours) |> max(1)
    to = DateTime.from_unix!(current_hour() + 3600)
    {DateTime.add(to, -hours * 3600, :second), to, hours}
  end

  # A select map of every counter's sum, as an integer.
  defp sums do
    for counter <- @counters, into: %{} do
      {counter, dynamic([r], type(coalesce(sum(field(r, ^counter)), 0), :integer))}
    end
  end

  defp sum_maps([]), do: Map.new(@counters, &{&1, 0})

  defp sum_maps(maps) do
    Map.new(@counters, fn c -> {c, maps |> Enum.map(&Map.get(&1, c, 0)) |> Enum.sum()} end)
  end

  defp with_means(%{} = sums) do
    n = sums.requests

    per_request =
      if n > 0 do
        %{
          response_bytes: div(sums.response_bytes, n),
          duration_ms: Float.round(sums.duration_us / n / 1000, 2),
          db_ms: Float.round(sums.db_us / n / 1000, 2),
          db_queries: Float.round(sums.db_queries / n, 2),
          upstream_calls:
            Float.round(
              (sums.node_calls + sums.woc_calls + sums.coingecko_calls + sums.other_calls) / n,
              3
            )
        }
      end

    Map.put(sums, :per_request, per_request)
  end

  @doc "Bytes as B, KB, MB, GB or TB (powers of 1,000), for reports."
  def format_bytes(n) when is_integer(n) and n < 1_000, do: "#{n} B"

  def format_bytes(n) when is_integer(n) do
    {size, unit} =
      Enum.find([{1.0e12, "TB"}, {1.0e9, "GB"}, {1.0e6, "MB"}, {1.0e3, "KB"}], fn {d, _} ->
        n >= d
      end)

    "#{Float.round(n / size, 1)} #{unit}"
  end

  defp class_order(class), do: Enum.find_index(@classes, &(&1 == class)) || length(@classes)

  # Names for the keys and users in a report: one query each, bounded by the
  # callers listed.
  defp label_callers(callers) do
    key_ids =
      for %{caller_kind: "key", caller_id: id} <- callers, {n, ""} <- [Integer.parse(id)], do: n

    user_ids =
      for %{caller_kind: "user", caller_id: id} <- callers, {n, ""} <- [Integer.parse(id)], do: n

    keys =
      if key_ids == [],
        do: %{},
        else:
          from(k in Bitblocks.ApiKeys.ApiKey,
            where: k.id in ^key_ids,
            select: {k.id, k.name, k.prefix}
          )
          |> Repo.all()
          |> Map.new(fn {id, name, prefix} -> {to_string(id), "#{name} (#{prefix})"} end)

    users =
      if user_ids == [],
        do: %{},
        else:
          from(u in Bitblocks.Accounts.User, where: u.id in ^user_ids, select: {u.id, u.login})
          |> Repo.all()
          |> Map.new(fn {id, login} -> {to_string(id), "@" <> to_string(login)} end)

    Enum.map(callers, fn c ->
      label =
        case c do
          %{caller_kind: "key", caller_id: id} -> Map.get(keys, id, "key #{id}")
          %{caller_kind: "user", caller_id: id} -> Map.get(users, id, "user #{id}")
          %{caller_kind: "crawler", caller_id: family} -> "AI crawler: #{family}"
          _ -> "anonymous"
        end

      Map.put(c, :label, label)
    end)
  end
end
