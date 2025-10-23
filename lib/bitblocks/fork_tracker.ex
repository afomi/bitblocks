defmodule Bitblocks.ForkTracker do
  @moduledoc """
  Tracks competing chain tips and divergent branches from multiple gossip sources.

  The tracker polls `getchaintips` from the configured Bitcoin node, allows
  manual ingestion of gossip events, persists a compact branch DAG to disk, and
  broadcasts deltas to interested LiveViews.
  """

  use GenServer

  require Logger

  alias Phoenix.PubSub

  @pubsub Bitblocks.PubSub
  @default_poll_interval :timer.seconds(10)
  @default_retention 256
  @default_state_path Path.join(["tmp", "fork_tracker", "state.etf"])
  @default_log_path Path.join(["tmp", "fork_tracker", "fork_tape.log"])
  @topic "fork_tracker"

  defmodule Node do
    @moduledoc false

    @enforce_keys [:hash, :height]
    defstruct hash: nil,
              parent: nil,
              height: nil,
              chainwork: 0,
              status: :unknown,
              timestamp: nil,
              branch_root: :main,
              branch_depth: 0,
              branch_offset: 0,
              source: "bitcoind"
  end

  defmodule Tip do
    @moduledoc false

    @enforce_keys [:hash, :height, :status]
    defstruct hash: nil,
              height: nil,
              status: :main,
              branch_len: 0,
              branch_root: :main,
              chainwork: 0,
              source: "bitcoind",
              updated_at: nil
  end

  defmodule State do
    @moduledoc false

    defstruct nodes: %{},
              tips: %{},
              version: 0,
              poll_interval: nil,
              poll_ref: nil,
              retention: nil,
              state_path: nil,
              log_path: nil,
              last_poll: nil,
              branch_offsets: %{},
              base_height: nil
  end

  # Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def subscribe do
    PubSub.subscribe(@pubsub, @topic)
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Resets the tracker state.

  Primarily used in tests to clear any cached fork information.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  def ingest_chaintips(tips, opts \\ []) when is_list(tips) do
    GenServer.cast(__MODULE__, {:ingest_tips, tips, opts})
  end

  def force_poll do
    GenServer.cast(__MODULE__, :force_poll)
  end

  def recent_events(limit \\ 20) do
    GenServer.call(__MODULE__, {:recent_events, limit})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    state_path = Keyword.get(opts, :state_path, @default_state_path)
    log_path = Keyword.get(opts, :log_path, @default_log_path)
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    retention = Keyword.get(opts, :retention, @default_retention)

    File.mkdir_p!(Path.dirname(state_path))
    File.mkdir_p!(Path.dirname(log_path))

    state =
      state_path
      |> load_state()
      |> Map.from_struct()
      |> Map.merge(%{
        state_path: state_path,
        log_path: log_path,
        poll_interval: poll_interval,
        retention: retention
      })
      |> (fn attrs -> struct(State, attrs) end).()
      |> recompute_branch_offsets()

    send(self(), :initial_poll)

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, serialize_snapshot(state), state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    now = DateTime.utc_now()
    removed_hashes = Map.keys(state.nodes)

    cancel_poll_timer(state.poll_ref)
    flush_internal_messages()

    cleared_state =
      %State{
        state
        | nodes: %{},
          tips: %{},
          base_height: nil,
          branch_offsets: %{},
          poll_ref: nil,
          last_poll: nil
      }
      |> assign_branch_offsets()
      |> bump_version()

    delta = compute_delta(state, cleared_state, [], removed_hashes, now)

    if cleared_state.log_path, do: safe_delete(cleared_state.log_path)
    if cleared_state.state_path, do: safe_delete(cleared_state.state_path)

    broadcast_delta(delta)

    {:ok, _} = persist_state(cleared_state, persist: false)

    {:reply, :ok, cleared_state}
  end

  @impl true
  def handle_call({:recent_events, limit}, _from, state) do
    {:reply, read_recent_events(state.log_path, limit), state}
  end

  @impl true
  def handle_cast(:force_poll, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:ingest_tips, tips, opts}, state) do
    source = Keyword.get(opts, :source, "bitcoind")
    now = DateTime.utc_now()

    {new_state, delta} =
      state
      |> ingest_tips(tips, source, now)

    broadcast_delta(delta)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:initial_poll, state) do
    send(self(), :poll)
    {:noreply, schedule_poll(%{state | last_poll: DateTime.utc_now()})}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state =
      case fetch_chaintips() do
        {:ok, tips} ->
          {next_state, delta} =
            state
            |> ingest_tips(tips, "bitcoind", DateTime.utc_now())

          broadcast_delta(delta)

          next_state

        {:error, reason} ->
          Logger.error("ForkTracker poll failed: #{inspect(reason)}")
          state
      end

    {:noreply, schedule_poll(%{new_state | last_poll: DateTime.utc_now()})}
  end

  @impl true
  def terminate(_reason, state) do
    persist_state(state)
    :ok
  end

  # Internal logic

  defp schedule_poll(%State{poll_interval: nil} = state), do: state

  defp schedule_poll(%State{poll_interval: interval, poll_ref: ref} = state) do
    if is_reference(ref), do: Process.cancel_timer(ref)
    %{state | poll_ref: Process.send_after(self(), :poll, interval)}
  end

  defp ingest_tips(state, [], _source, _now), do: {state, empty_delta(state)}

  defp ingest_tips(state, tips, source, now) do
    old_state = state

    {nodes_intermediate, tips_map, inserted_nodes} =
      Enum.reduce(tips, {state.nodes, state.tips, []}, fn tip, {nodes_acc, tips_acc, inserted} ->
        process_tip(nodes_acc, tips_acc, inserted, tip, source, now)
      end)

    {nodes, history_nodes} = ensure_main_history(nodes_intermediate, tips_map, state.retention)
    inserted_nodes = inserted_nodes ++ history_nodes

    {pruned_nodes, removed_hashes} = prune_nodes(nodes, tips_map, state.retention)
    base_height = compute_base_height(pruned_nodes)

    updated_state =
      %State{state | nodes: pruned_nodes, tips: tips_map, base_height: base_height}
      |> assign_branch_offsets()
      |> bump_version()

    delta = compute_delta(old_state, updated_state, inserted_nodes, removed_hashes, now)

    persist_state(updated_state)
    append_tape(delta, updated_state.log_path)

    {updated_state, delta}
  end

  defp process_tip(nodes, tips, inserted, %{"hash" => hash} = tip, source, now) do
    height = tip["height"]
    branch_len = tip["branchlen"] || 0
    status = normalize_status(tip["status"])

    {nodes_after_branch, new_nodes, branch_root} =
      build_branch(hash, branch_len, branch_len, nodes, status, source)

    existing_node = Map.get(nodes_after_branch, hash)

    chainwork =
      tip["chainwork"]
      |> parse_chainwork()
      |> max((existing_node && existing_node.chainwork) || 0)

    updated_tip_node =
      case existing_node do
        nil -> existing_node
        node -> %{node | chainwork: chainwork, status: status}
      end

    nodes_final =
      case updated_tip_node do
        nil -> nodes_after_branch
        node -> Map.put(nodes_after_branch, hash, node)
      end

    tip_record = %Tip{
      hash: hash,
      height: height,
      status: status,
      branch_len: branch_len,
      branch_root: branch_root,
      chainwork: chainwork,
      source: source,
      updated_at: now
    }

    {nodes_final, Map.put(tips, hash, tip_record), inserted ++ new_nodes}
  end

  defp process_tip(nodes, tips, inserted, _bad, _source, _now) do
    {nodes, tips, inserted}
  end

  defp build_branch(hash, remaining, total, nodes, status, source) do
    case Map.fetch(nodes, hash) do
      {:ok, existing} ->
        {nodes, [], existing.branch_root}

      :error ->
        header =
          case fetch_header(hash) do
            {:ok, h} ->
              h

            {:error, reason} ->
              Logger.error("ForkTracker failed to fetch header #{hash}: #{inspect(reason)}")
              nil
          end

        cond do
          header == nil ->
            {nodes, [], :main}

          true ->
            parent_hash = header["previousblockhash"]

            {nodes_after_parent, inserted_parent, root} =
              if remaining > 0 && parent_hash do
                build_branch(parent_hash, remaining - 1, total, nodes, status, source)
              else
                {nodes, [], :main}
              end

            branch_root =
              cond do
                total > 0 && remaining == 0 -> hash
                root != :main -> root
                total > 0 -> hash
                true -> :main
              end

            node_status =
              cond do
                remaining == total -> status
                total > 0 && remaining == 0 -> :main
                total > 0 -> :fork
                true -> status
              end

            node = %Node{
              hash: hash,
              parent: parent_hash,
              height: header["height"],
              chainwork: parse_chainwork(header["chainwork"]),
              status: node_status,
              timestamp: header["time"] && DateTime.from_unix!(header["time"]),
              branch_root: branch_root,
              branch_depth: remaining,
              source: source
            }

            nodes_with_node = Map.put(nodes_after_parent, hash, node)
            {nodes_with_node, inserted_parent ++ [node], branch_root}
        end
    end
  end

  defp prune_nodes(nodes, tips, retention) do
    keep =
      tips
      |> Map.values()
      |> Enum.reduce(MapSet.new(), fn tip, acc ->
        walk_branch(tip.hash, nodes, tip.branch_len + retention, acc)
      end)

    pruned_nodes = Map.take(nodes, MapSet.to_list(keep))
    removed = Map.keys(nodes) -- Map.keys(pruned_nodes)
    {pruned_nodes, removed}
  end

  defp ensure_main_history(nodes, tips, depth) do
    main_tip =
      tips
      |> Map.values()
      |> Enum.filter(&(&1.status == :main and &1.branch_len == 0))
      |> Enum.max_by(& &1.height, fn -> nil end)

    case main_tip do
      nil ->
        {nodes, []}

      %Tip{hash: hash, source: source} ->
        extend_history(hash, depth, nodes, source, [], MapSet.new())
    end
  end

  defp extend_history(_hash, depth, nodes, _source, acc, _seen) when depth <= 0 do
    {nodes, acc}
  end

  defp extend_history(hash, _depth, nodes, _source, acc, _seen) when is_nil(hash) do
    {nodes, acc}
  end

  defp extend_history(hash, depth, nodes, source, acc, seen) do
    case Map.get(nodes, hash) do
      nil ->
        {nodes, acc}

      %Node{parent: nil} ->
        {nodes, acc}

      %Node{parent: parent} ->
        cond do
          MapSet.member?(seen, parent) ->
            {nodes, acc}

          Map.has_key?(nodes, parent) ->
            extend_history(parent, depth - 1, nodes, source, acc, MapSet.put(seen, parent))

          true ->
            {nodes_with_parent, inserted, _root} =
              build_branch(parent, 0, 0, nodes, :main, source)

            new_seen = MapSet.put(seen, parent)

            extend_history(
              parent,
              depth - 1,
              nodes_with_parent,
              source,
              acc ++ inserted,
              new_seen
            )
        end
    end
  end

  defp walk_branch(nil, _nodes, _remaining, acc), do: acc

  defp walk_branch(_hash, _nodes, remaining, acc) when remaining < 0 do
    acc
  end

  defp walk_branch(hash, nodes, remaining, acc) do
    if MapSet.member?(acc, hash) do
      acc
    else
      case Map.get(nodes, hash) do
        nil ->
          acc

        node ->
          updated = MapSet.put(acc, hash)
          walk_branch(node.parent, nodes, remaining - 1, updated)
      end
    end
  end

  defp assign_branch_offsets(%State{tips: tips, nodes: nodes} = state) do
    branch_keys =
      tips
      |> Enum.map(fn {_hash, tip} -> tip.branch_root end)
      |> Enum.reject(&(&1 == :main))
      |> Enum.uniq()

    offsets =
      branch_keys
      |> Enum.with_index(1)
      |> Enum.into(%{main: 0})

    normalized_nodes =
      Enum.reduce(nodes, %{}, fn {hash, node}, acc ->
        branch_key = normalize_branch_key(node.branch_root)
        offset = Map.get(offsets, branch_key, 0)
        Map.put(acc, hash, %{node | branch_offset: offset})
      end)

    %{state | nodes: normalized_nodes, branch_offsets: offsets}
  end

  defp recompute_branch_offsets(%State{} = state) do
    assign_branch_offsets(state)
  end

  defp normalize_branch_key(:main), do: :main
  defp normalize_branch_key(nil), do: :main
  defp normalize_branch_key(hash), do: hash

  defp compute_base_height(nodes) do
    nodes
    |> Map.values()
    |> Enum.map(& &1.height)
    |> Enum.min(fn -> nil end)
  end

  defp bump_version(%State{version: version} = state) do
    %{state | version: version + 1}
  end

  defp compute_delta(old_state, new_state, inserted_nodes, removed_hashes, now) do
    old_nodes = old_state.nodes
    new_nodes = new_state.nodes

    updated =
      new_nodes
      |> Enum.filter(fn {hash, node} ->
        case Map.fetch(old_nodes, hash) do
          {:ok, old_node} -> old_node != node
          :error -> false
        end
      end)
      |> Enum.map(fn {_hash, node} -> node end)

    removed = Enum.map(removed_hashes, &%{hash: &1})

    new_tips =
      Enum.map(new_state.tips, fn {_hash, tip} -> tip end)

    %{
      version: new_state.version,
      timestamp: now,
      nodes: %{
        added: Enum.map(inserted_nodes, &node_to_event/1),
        updated: Enum.map(updated, &node_to_event/1),
        removed: removed
      },
      tips: Enum.map(new_tips, &tip_to_event/1),
      base_height: new_state.base_height,
      branch_offsets: new_state.branch_offsets
    }
  end

  defp empty_delta(state) do
    %{
      version: state.version,
      timestamp: DateTime.utc_now(),
      nodes: %{added: [], updated: [], removed: []},
      tips: Enum.map(state.tips, fn {_hash, tip} -> tip_to_event(tip) end),
      base_height: state.base_height,
      branch_offsets: state.branch_offsets
    }
  end

  defp node_to_event(%Node{} = node) do
    %{
      hash: node.hash,
      parent: node.parent,
      height: node.height,
      chainwork: node.chainwork,
      status: node.status,
      timestamp: format_time(node.timestamp),
      branch_root: node.branch_root,
      branch_depth: node.branch_depth,
      branch_offset: node.branch_offset,
      source: node.source
    }
  end

  defp tip_to_event(%Tip{} = tip) do
    %{
      hash: tip.hash,
      height: tip.height,
      status: tip.status,
      branch_len: tip.branch_len,
      branch_root: tip.branch_root,
      chainwork: tip.chainwork,
      source: tip.source,
      updated_at: format_time(tip.updated_at)
    }
  end

  defp serialize_snapshot(%State{} = state) do
    %{
      version: state.version,
      base_height: state.base_height,
      branch_offsets: state.branch_offsets,
      nodes:
        state.nodes
        |> Map.values()
        |> Enum.map(&node_to_event/1),
      tips:
        state.tips
        |> Map.values()
        |> Enum.map(&tip_to_event/1)
    }
  end

  defp broadcast_delta(delta) do
    PubSub.broadcast(@pubsub, @topic, {:fork_update, delta})
  end

  defp persist_state(state, opts \\ [])
  defp persist_state(%State{state_path: nil}, _opts), do: {:ok, :skipped}

  defp persist_state(%State{} = state, opts) do
    serializable = %{
      version: state.version,
      nodes: state.nodes,
      tips: state.tips,
      branch_offsets: state.branch_offsets,
      base_height: state.base_height
    }

    if Keyword.get(opts, :persist, true) do
      File.write!(state.state_path, :erlang.term_to_binary(serializable))
    end

    {:ok, serializable}
  end

  defp load_state(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> :erlang.binary_to_term()
      |> rebuild_state()
    else
      %State{}
    end
  rescue
    _ -> %State{}
  end

  defp rebuild_state(%{
         version: version,
         nodes: nodes,
         tips: tips,
         branch_offsets: offsets,
         base_height: base
       }) do
    struct(State, %{
      version: version,
      nodes: nodes,
      tips: tips,
      branch_offsets: offsets,
      base_height: base
    })
  end

  defp rebuild_state(_), do: %State{}

  defp cancel_poll_timer(nil), do: :ok
  defp cancel_poll_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_poll_timer(_), do: :ok

  defp flush_internal_messages do
    flush_message(:poll)
    flush_message(:initial_poll)
  end

  defp flush_message(message) do
    receive do
      ^message -> flush_message(message)
    after
      0 -> :ok
    end
  end

  defp safe_delete(nil), do: :ok

  defp safe_delete(path) do
    if File.exists?(path) do
      File.rm(path)
    else
      :ok
    end
  end

  defp append_tape(delta, path) do
    entries =
      delta.tips
      |> Enum.filter(fn tip -> tip.branch_len > 0 or tip.status != :main end)
      |> Enum.map(fn tip ->
        [
          DateTime.utc_now() |> DateTime.to_iso8601(),
          tip.hash,
          Atom.to_string(tip.status),
          "branch_len=#{tip.branch_len}",
          "root=#{tip.branch_root}",
          "source=#{tip.source}"
        ]
        |> Enum.join("|")
      end)

    case entries do
      [] ->
        :ok

      lines ->
        File.write!(path, Enum.map_join(lines, "\n", & &1) <> "\n", [:append])
    end
  end

  defp read_recent_events(path, limit) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.take(-limit)
    else
      []
    end
  end

  # RPC helpers

  defp fetch_chaintips do
    cli().getchaintips()
    |> wrap_result()
  end

  defp fetch_header(hash) do
    cli().getblockheader(hash, true)
    |> wrap_result()
  end

  defp wrap_result({:error, _} = error), do: error
  defp wrap_result({:ok, result}), do: {:ok, result}
  defp wrap_result(result), do: {:ok, result}

  defp cli do
    Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
  end

  # Utility

  defp parse_chainwork(nil), do: 0
  defp parse_chainwork(""), do: 0

  defp parse_chainwork(value) when is_binary(value) do
    value
    |> String.trim_leading("0x")
    |> case do
      "" ->
        0

      hex ->
        try do
          String.to_integer(hex, 16)
        rescue
          ArgumentError -> 0
        end
    end
  end

  defp parse_chainwork(value) when is_integer(value), do: value
  defp parse_chainwork(_), do: 0

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @status_lookup %{
    "active" => :main,
    "headers-only" => :headers_only,
    "invalid" => :invalid,
    "valid-fork" => :valid_fork,
    "valid-headers" => :valid_headers,
    "unknown" => :unknown
  }

  defp normalize_status(status) when is_binary(status) do
    Map.get(@status_lookup, String.downcase(status), :unknown)
  end

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(_), do: :unknown
end
