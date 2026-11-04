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

  # Our index this many blocks behind the node, with no new block for this
  # long, is stalled (not just catching up between minutes).
  @stall_blocks 6
  @stall_seconds 3_600

  # The same problem is emailed at most this often.
  @alert_every_seconds 6 * 3_600

  @doc "Health from live state."
  def health, do: health(facts())

  @doc """
  Health from given facts (for tests): `%{node: blockchain_info | {:error, _},
  overview: SyncProgress overview, latest_block_at: DateTime | nil, now:}`.
  """
  def health(%{node: node, overview: overview, now: now} = facts) do
    node_state = Config.node_status(node)
    node_blocks = if is_map(node), do: node["blocks"]
    node_headers = (is_map(node) && node["headers"]) || overview[:node_headers]
    our_tip = overview[:our_tip]
    latest_at = facts[:latest_block_at]

    index_behind = diff(node_headers, our_tip)
    idle = latest_at && DateTime.diff(now, latest_at)

    problems =
      Enum.reject(
        [
          match?({:unreachable, _}, node_state) && "node_unreachable",
          match?({:warming_up, _}, node_state) && "node_warming_up",
          (is_integer(index_behind) and index_behind > @stall_blocks and
             is_integer(idle) and idle > @stall_seconds) && "index_stalled"
        ],
        &(&1 == false)
      )

    %{
      status: status(problems),
      problems: problems,
      as_of: DateTime.to_iso8601(now),
      index: %{
        tip: our_tip,
        complete_through: overview[:complete_through],
        latest_block_at: latest_at && DateTime.to_iso8601(latest_at)
      },
      node: %{
        state: node_state_name(node_state),
        message: node_message(node_state),
        blocks: node_blocks,
        headers: node_headers
      },
      network: %{public_tip: overview[:public_tip]},
      release: facts[:release] || release(),
      lag: %{
        index_behind_node: index_behind,
        node_behind_network: diff(overview[:public_tip], node_headers)
      }
    }
  end

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
    %{sha: System.get_env("RELEASE_SHA"), node: to_string(node())}
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
    %{
      node: safe(fn -> RpcCache.get_blockchain_info() end),
      overview: SyncProgress.snapshot().overview,
      latest_block_at: latest_block_at(),
      now: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

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
  defp subject("index_stalled"), do: "Bitblocks: index stalled behind the node"
  defp subject(_), do: nil

  defp body("node_unreachable", h) do
    """
    Our BSV node isn't answering as of #{h.as_of}.
    Our index is at block #{h.index.tip}; the network is at #{h.network.public_tip}.
    Check it from your machine with scripts/bsvnode info.
    """
  end

  defp body("index_stalled", h) do
    """
    Our index is #{h.lag.index_behind_node} blocks behind the node, and no new block has been added since #{h.index.latest_block_at}.
    The node is at #{h.node.headers} headers; our tip is #{h.index.tip}.
    See /sync for the coordinator and job state.
    """
  end
end
