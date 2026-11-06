defmodule Bitblocks.Ops do
  @moduledoc """
  Operations as data: is Bitblocks healthy, and how current is it?

  One answer shared by `GET /api/v1/status`, the ops alert cron
  (`Bitblocks.Workers.OpsAlertWorker`) and, later, an operator MCP
  (docs/OPS_API_AND_MCP.md). It reads only cached state: the /syncing shared
  snapshot (`SyncProgress`), the node info cache (`RpcCache`) and our newest
  block row, so it is cheap enough for a public endpoint.

  It never carries the node's address or credentials.
  """

  alias Bitblocks.{Chain, Config, Notifications, RpcCache, SyncProgress}

  # A stall is no progress for this long while there is work to do: our
  # headers more than @stall_blocks behind the node's validated blocks with no
  # new header, or blocks above complete_through with none completed and none
  # being worked.
  @stall_blocks 6
  @stall_seconds 3_600

  # The same problem is emailed at most this often.
  @alert_every_seconds 6 * 3_600

  @doc "Health from live state."
  def health, do: health(facts())

  @doc """
  Health from given facts (for tests): `%{node: blockchain_info | {:error, _},
  overview: SyncProgress overview, latest_block_at: DateTime | nil,
  last_completed_at: DateTime | nil, blocks_in_progress: integer,
  paused: boolean, now:}`.

  `latest_block_at` is when our newest header row landed,
  `last_completed_at` when the newest block reached `completed`, and
  `blocks_in_progress` counts live block jobs on a block with no failures.

  Both lags are measured from the node's validated `blocks`, not its
  `headers`, which can run far ahead while the node catches up: ours behind
  it, and it behind the network.
  """
  def health(%{node: node, overview: overview, now: now} = facts) do
    node_state = Config.node_status(node)
    node_blocks = (is_map(node) && node["blocks"]) || overview[:node_tip]
    node_headers = (is_map(node) && node["headers"]) || overview[:node_headers]
    our_tip = overview[:our_tip]
    through = overview[:complete_through]
    public_tip = overview[:public_tip]
    latest_at = facts[:latest_block_at]
    completed_at = facts[:last_completed_at]

    index_behind = diff(node_blocks, our_tip)
    paused = facts[:paused] == true

    stalled =
      cond do
        # An operator's pause (Sync.paused?/0) is not a stall.
        paused ->
          nil

        is_integer(index_behind) and index_behind > @stall_blocks and idle?(latest_at, now) ->
          "headers"

        is_integer(through) and is_integer(our_tip) and through < our_tip and
          idle?(completed_at || latest_at, now) and (facts[:blocks_in_progress] || 0) == 0 ->
          "blocks"

        true ->
          nil
      end

    problems =
      Enum.reject(
        [
          match?({:unreachable, _}, node_state) && "node_unreachable",
          match?({:warming_up, _}, node_state) && "node_warming_up",
          stalled && "index_stalled",
          paused && "sync_paused",
          facts[:halted] && "reorg_halted"
        ],
        &(&1 in [false, nil])
      )

    %{
      status: status(problems),
      problems: problems,
      as_of: DateTime.to_iso8601(now),
      index: %{
        tip: our_tip,
        complete_through: through,
        latest_block_at: iso(latest_at),
        last_completed_at: iso(completed_at),
        stalled: stalled,
        paused: paused,
        halted_at: facts[:halted],
        failed: failed(overview[:states])
      },
      node: %{
        state: node_state_name(node_state),
        message: node_message(node_state),
        blocks: node_blocks,
        headers: node_headers
      },
      network: %{public_tip: public_tip},
      release: facts[:release] || release(),
      lag: %{
        index_behind_node: index_behind,
        node_behind_network: diff(public_tip, node_blocks),
        node_headers_behind_network: diff(public_tip, node_headers)
      }
    }
  end

  # A single large block can take longer than an hour, which is why a clean
  # job in progress counts as progress; a failing one has its own email
  # (Notifications.sync_stall_alert/3) and counts as a stall here.
  defp idle?(nil, _now), do: false
  defp idle?(at, now), do: DateTime.diff(now, at) > @stall_seconds

  # Blocks in `failed` (retrying; nothing is parked), from the snapshot's
  # per-state counts. nil before the first count.
  defp failed(states) when is_list(states),
    do: Enum.find_value(states, 0, fn {s, n} -> s == "failed" && n end)

  defp failed(_), do: nil

  defp iso(nil), do: nil
  defp iso(at), do: DateTime.to_iso8601(at)

  @doc """
  Emails each problem in `health` once per #{div(@alert_every_seconds, 3600)} hours.
  Returns the problems emailed.
  """
  def alert(%{problems: problems} = health) do
    now = System.system_time(:second)

    for problem <- problems,
        subject = subject(problem),
        subject != nil,
        due?(problem, now) do
      Notifications.ops_alert(subject, body(problem, health))
      :persistent_term.put({__MODULE__, :alerted, problem}, now)
      problem
    end
  end

  @doc false
  def reset_alerts do
    for problem <- ~w(node_unreachable index_stalled),
        do: :persistent_term.erase({__MODULE__, :alerted, problem})

    :ok
  end

  @doc """
  The running release: the image's git sha (RELEASE_SHA, set by
  .github/scripts/deploy.sh from the image tag) and this node's name, so a
  deploy can be confirmed from the outside.
  """
  def release do
    # The node name carries its private IP (bitblocks@10.x.x.x); expose only a
    # short stable id, enough to tell the two app nodes apart.
    %{
      sha: System.get_env("RELEASE_SHA"),
      node: "node-" <> (node() |> :erlang.phash2() |> Integer.to_string(16) |> String.downcase())
    }
  end

  # Inlined as a literal in the bucket query, so GROUP BY and SELECT match.
  @bucket 10_000
  @coverage_ttl_ms 60_000

  @doc """
  Coverage as a curve: completeness per #{@bucket}-block bucket, blocks
  completed in the last hour, and an ETA to the tip at that rate. Computed at
  most once a minute and shared (two index-only queries on `blocks`).
  """
  def coverage do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :coverage}, nil) do
      {at, value} when now - at < @coverage_ttl_ms ->
        value

      _ ->
        value = coverage(coverage_facts())
        :persistent_term.put({__MODULE__, :coverage}, {now, value})
        value
    end
  end

  @doc "Coverage from given facts (for tests)."
  def coverage(%{buckets: buckets, complete_through: through, tip: tip} = facts) do
    rate = facts[:completed_last_hour] || 0
    remaining = if is_integer(tip) and is_integer(through), do: max(tip - through, 0), else: nil

    %{
      bucket_size: @bucket,
      complete_through: through,
      tip: tip,
      remaining: remaining,
      blocks_per_hour: rate,
      eta_hours: if(rate > 0 and is_integer(remaining), do: Float.round(remaining / rate, 1)),
      buckets:
        Enum.map(buckets, fn %{bucket: b, present: present, completed: completed} ->
          %{
            from: b * @bucket,
            to: b * @bucket + @bucket - 1,
            present: present,
            completed: completed,
            complete_pct: Float.round(completed * 100 / @bucket, 1)
          }
        end)
    }
  end

  defp coverage_facts do
    import Ecto.Query
    alias Bitblocks.Chain.Block

    buckets =
      Bitblocks.Repo.all(
        from(b in Block,
          group_by: fragment("? / 10000", b.height),
          order_by: fragment("? / 10000", b.height),
          select: %{
            bucket: fragment("? / 10000", b.height),
            present: count(b.id),
            completed: fragment("count(*) FILTER (WHERE ? = 'completed')", b.sync_state)
          }
        ),
        timeout: 15_000
      )

    hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second)

    completed_last_hour =
      Bitblocks.Repo.one(
        from(b in Block, where: b.tx_sync_completed_at >= ^hour_ago, select: count(b.id))
      )

    s = Bitblocks.Sync.status()

    %{
      buckets: buckets,
      complete_through: s.complete_through,
      tip: s.tip,
      completed_last_hour: completed_last_hour
    }
  end

  # -- Facts ---------------------------------------------------------------------

  defp facts do
    snapshot = SyncProgress.snapshot()

    %{
      node: safe(fn -> RpcCache.get_blockchain_info() end),
      overview: snapshot.overview,
      latest_block_at: latest_block_at(),
      last_completed_at: last_completed_at(snapshot.recent),
      blocks_in_progress: blocks_in_progress(snapshot.sync),
      paused: safe(&Bitblocks.Sync.paused?/0) == true,
      halted: halted_fork(),
      now: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  @doc false
  # The newest completion among the snapshot's recent blocks (read from
  # blocks_tx_sync_completed_at_index, refreshed every 30 s).
  def last_completed_at(recent) do
    recent
    |> Enum.map(& &1[:tx_sync_completed_at])
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc false
  # Live block jobs on an incomplete block that hasn't failed: the loop is
  # working, even if nothing has completed lately.
  def blocks_in_progress(%{rows: rows}) do
    Enum.count(rows, fn row ->
      row[:job_state] != nil and row[:sync_state] != "completed" and (row[:failures] || 0) == 0
    end)
  end

  def blocks_in_progress(_), do: 0

  defp latest_block_at do
    case safe(&Chain.get_latest_block/0) do
      %{inserted_at: %NaiveDateTime{} = at} -> DateTime.from_naive!(at, "Etc/UTC")
      %{inserted_at: %DateTime{} = at} -> at
      _ -> nil
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # -- Shape ---------------------------------------------------------------------

  defp status(problems) do
    cond do
      "node_unreachable" in problems -> "down"
      problems != [] -> "degraded"
      true -> "ok"
    end
  end

  # The height tip sync can't pass (#34), or nil. Nil too when the query
  # fails: the deploy health check can answer before bin/migrate.
  defp halted_fork do
    case safe(&Bitblocks.Reorgs.halted/0) do
      %{fork_height: height} -> height
      _ -> nil
    end
  end

  defp node_state_name(:ok), do: "ok"
  defp node_state_name({:warming_up, _}), do: "warming_up"
  defp node_state_name({:unreachable, _}), do: "unreachable"

  defp node_message({:warming_up, message}), do: message
  defp node_message(_), do: nil

  defp diff(a, b) when is_integer(a) and is_integer(b), do: a - b
  defp diff(_, _), do: nil

  defp due?(problem, now) do
    case :persistent_term.get({__MODULE__, :alerted, problem}, nil) do
      nil -> true
      at -> now - at >= @alert_every_seconds
    end
  end

  defp subject("node_unreachable"), do: "Bitblocks: node unreachable"
  defp subject("index_stalled"), do: "Bitblocks: index stalled"
  defp subject(_), do: nil

  defp body("node_unreachable", h) do
    """
    Our BSV node isn't answering as of #{h.as_of}.
    Our index is at block #{h.index.tip}; the network is at #{h.network.public_tip}.
    Check it from your machine with scripts/bsvnode info.
    """
  end

  defp body("index_stalled", %{index: %{stalled: "headers"}} = h) do
    """
    Our headers are #{h.lag.index_behind_node} blocks behind the node, and no new header has landed since #{h.index.latest_block_at}.
    The node has validated #{h.node.blocks} blocks; our newest header is #{h.index.tip}.
    See /syncing for the coordinator.
    """
  end

  defp body("index_stalled", h) do
    """
    No block has completed since #{h.index.last_completed_at || h.index.latest_block_at}, and no block job is working without failures.
    Complete through block #{h.index.complete_through} of #{h.index.tip} known; the node is #{h.node.state}.
    See /syncing for the coordinator.
    """
  end
end
