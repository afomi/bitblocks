defmodule BitblocksWeb.SyncLive do
  use BitblocksWeb, :live_view

  # Destructive actions (clear blocks/transactions) are only available in dev/test.
  @dev_mode Application.compile_env(:bitblocks, :env, :prod) != :prod

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Blockchain Sync",
        dev_mode: @dev_mode,
        scope_type: "range",
        form_errors: [],
        chain_tip: nil,
        blocks_count: 0,
        transactions_count: 0,
        block_states: %{},
        oban_summary: %{jobs: [], headers: 0, tx_fetch: 0, tip: false}
      )

    if connected?(socket) do
      send(self(), :load_data)
      Process.send_after(self(), :poll_status, 10_000)
    end

    {:ok, socket}
  end

  defp get_chain_tip do
    case Bitblocks.RpcCache.get_blockchain_info() do
      %{"blocks" => blocks, "headers" => headers} = info ->
        verification_progress = Map.get(info, "verificationprogress", 1.0)

        %{
          blocks: blocks,
          headers: headers,
          synced: blocks == headers,
          verification_progress: verification_progress
        }

      _ ->
        nil
    end
  end

  defp get_db_counts do
    {Bitblocks.StatsCache.blocks_count(), Bitblocks.StatsCache.transactions_count()}
  end

  @impl true
  def handle_event("scope_type_changed", %{"value" => scope_type}, socket) do
    {:noreply, assign(socket, scope_type: scope_type, form_errors: [])}
  end

  @impl true
  def handle_event("scope_type_changed", %{"scope_type" => scope_type}, socket) do
    {:noreply, assign(socket, scope_type: scope_type, form_errors: [])}
  end


  @impl true
  def handle_event("start_sync", params, socket) do
    case build_scope(socket.assigns.scope_type, params) do
      {:ok, {from, to}} ->
        case %{"mode" => "range", "from" => from, "to" => to}
             |> Bitblocks.Workers.SyncHeadersWorker.new()
             |> Oban.insert() do
          {:ok, _job} ->
            {:noreply,
             socket
             |> put_flash(:info, "Header sync queued for blocks #{from}..#{to}")
             |> assign(form_errors: [])
             |> refresh_status()}

          {:error, _} ->
            {:noreply, assign(socket, form_errors: ["Sync job already queued for this range"])}
        end

      {:error, errors} ->
        {:noreply, assign(socket, form_errors: errors)}
    end
  end

  @impl true
  def handle_event("stop_sync", _params, socket) do
    import Ecto.Query

    {cancelled, _} =
      from(j in Oban.Job,
        where: j.worker == "Bitblocks.Workers.SyncHeadersWorker",
        where: j.state in ["available", "scheduled", "executing"]
      )
      |> Bitblocks.Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    {:noreply,
     socket
     |> put_flash(:info, "Cancelled #{cancelled} sync job(s)")
     |> refresh_status()}
  end

  @impl true
  def handle_event("start_tip_sync", _params, socket) do
    %{"mode" => "tip"}
    |> Bitblocks.Workers.SyncHeadersWorker.new()
    |> Oban.insert()

    {:noreply,
     socket
     |> put_flash(:info, "Tip sync started")
     |> refresh_status()}
  end

  @impl true
  def handle_event("stop_tip_sync", _params, socket) do
    import Ecto.Query

    {cancelled, _} =
      from(j in Oban.Job,
        where: j.worker == "Bitblocks.Workers.SyncHeadersWorker",
        where: j.state in ["available", "scheduled"],
        where: fragment("args->>'mode' = 'tip'")
      )
      |> Bitblocks.Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    {:noreply,
     socket
     |> put_flash(:info, "Cancelled #{cancelled} tip sync job(s)")
     |> refresh_status()}
  end

  @impl true
  def handle_event("clear_blocks", _params, %{assigns: %{dev_mode: true}} = socket) do
    {count, _} = Bitblocks.Repo.delete_all(Bitblocks.Chain.Block)
    {blocks_count, transactions_count} = get_db_counts()

    {:noreply,
     socket
     |> put_flash(:info, "Deleted #{count} blocks")
     |> assign(blocks_count: blocks_count, transactions_count: transactions_count)}
  end

  @impl true
  def handle_event("clear_transactions", _params, %{assigns: %{dev_mode: true}} = socket) do
    {count, _} = Bitblocks.Repo.delete_all(Bitblocks.Chain.Transaction)
    {blocks_count, transactions_count} = get_db_counts()

    {:noreply,
     socket
     |> put_flash(:info, "Deleted #{count} transactions")
     |> assign(blocks_count: blocks_count, transactions_count: transactions_count)}
  end

  @impl true
  def handle_event("start_backfill", _params, socket) do
    chain_tip = get_chain_tip()
    to = if chain_tip, do: chain_tip.blocks, else: 0

    case %{"mode" => "range", "from" => 0, "to" => to}
         |> Bitblocks.Workers.SyncHeadersWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "Backfill queued: blocks 0..#{to}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :info, "Backfill already running.")}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, refresh_status(socket)}
  end

  @impl true
  def handle_info(:poll_status, socket) do
    Process.send_after(self(), :poll_status, 10_000)
    {:noreply, refresh_status(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp refresh_status(socket) do
    {blocks_count, transactions_count} = get_db_counts()

    assign(socket,
      chain_tip: get_chain_tip(),
      blocks_count: blocks_count,
      transactions_count: transactions_count,
      block_states: get_block_states(),
      oban_summary: get_oban_summary()
    )
  end

  defp build_scope("all", _params) do
    # Resolve "all" to 0..tip range
    case Bitblocks.RpcCache.get_blockchain_info() do
      %{"blocks" => tip} ->
        {:ok, {0, tip}}

      _ ->
        {:error, ["Failed to get blockchain info from node"]}
    end
  end

  defp build_scope("range", %{"start_block" => start_str, "end_block" => end_str}) do
    with {start_block, ""} <- Integer.parse(start_str),
         {end_block, ""} <- Integer.parse(end_str),
         true <- start_block >= 0,
         true <- end_block >= start_block do
      {:ok, {start_block, end_block}}
    else
      _ ->
        {:error, ["Invalid block range. Start and end must be valid integers with end >= start."]}
    end
  end

  defp build_scope("from_block", %{"start_block" => start_str}) do
    # Resolve "from block to tip" to start..tip range
    with {start_block, ""} <- Integer.parse(start_str),
         true <- start_block >= 0,
         %{"blocks" => tip} <- Bitblocks.RpcCache.get_blockchain_info() do
      {:ok, {start_block, tip}}
    else
      _ ->
        {:error, ["Invalid start block or failed to get blockchain info from node"]}
    end
  end

  defp build_scope(_, _) do
    {:error, ["Please select a valid sync scope"]}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-6xl">
      <h1 class="text-4xl font-bold mb-6 text-gray-900 dark:text-white">
        Blockchain Sync
      </h1>

      <%!-- Chain Status --%>
      <BitblocksWeb.ChainStatusComponent.chain_status
        chain_tip={@chain_tip}
        blocks_count={@blocks_count}
        transactions_count={@transactions_count}
      />

      <%!-- Block State Breakdown --%>
      <div class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6">
        <h2 class="text-lg font-semibold mb-4 text-gray-900 dark:text-white">
          Block States
        </h2>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm">
          <div>
            <div class="text-gray-500 dark:text-gray-400">Completed</div>
            <div class="text-2xl font-mono font-semibold text-green-600">
              <%= format_number(Map.get(@block_states, "completed", 0)) %>
            </div>
          </div>
          <div>
            <div class="text-gray-500 dark:text-gray-400">Syncing Txs</div>
            <div class="text-2xl font-mono font-semibold text-blue-600">
              <%= format_number(Map.get(@block_states, "txs_syncing", 0) + Map.get(@block_states, "txs_queued", 0)) %>
            </div>
          </div>
          <div>
            <div class="text-gray-500 dark:text-gray-400">Header Only</div>
            <div class="text-2xl font-mono font-semibold text-gray-600 dark:text-gray-300">
              <%= format_number(Map.get(@block_states, "header_only", 0) + Map.get(@block_states, "header_synced", 0)) %>
            </div>
          </div>
          <div>
            <div class="text-gray-500 dark:text-gray-400">Failed</div>
            <div class={[
              "text-2xl font-mono font-semibold",
              if(Map.get(@block_states, "failed", 0) > 0, do: "text-red-600", else: "text-gray-400")
            ]}>
              <%= format_number(Map.get(@block_states, "failed", 0)) %>
            </div>
          </div>
        </div>
      </div>

      <%!-- Active Jobs --%>
      <div class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold text-gray-900 dark:text-white">
            Jobs
            <span class="text-sm font-normal text-gray-500 dark:text-gray-400 ml-2">
              refreshes every 10s
            </span>
          </h2>
          <div class="flex items-center gap-3">
            <%!-- Tip Sync toggle --%>
            <%= if @oban_summary.tip do %>
              <span class="flex items-center gap-1.5 text-xs text-green-600">
                <span class="inline-block w-2 h-2 rounded-full bg-green-500 animate-pulse"></span>
                Tip sync active
              </span>
              <button
                phx-click="stop_tip_sync"
                class="px-3 py-1 text-xs bg-red-100 text-red-700 dark:bg-red-900/50 dark:text-red-300 rounded hover:bg-red-200"
              >
                Stop
              </button>
            <% else %>
              <button
                phx-click="start_tip_sync"
                class="px-3 py-1 text-xs bg-green-100 text-green-700 dark:bg-green-900/50 dark:text-green-300 rounded hover:bg-green-200"
              >
                Start Tip Sync
              </button>
            <% end %>
          </div>
        </div>

        <%= if @oban_summary.jobs == [] do %>
          <p class="text-sm text-gray-500 dark:text-gray-400 py-4">
            No active jobs.
          </p>
        <% else %>
          <div class="space-y-1">
            <%= for job <- @oban_summary.jobs do %>
              <div class="flex items-center justify-between py-2 px-3 rounded text-sm bg-gray-50 dark:bg-gray-900/50">
                <div class="flex items-center gap-3">
                  <span class={[
                    "inline-block w-2 h-2 rounded-full",
                    case job.state do
                      "executing" -> "bg-blue-500 animate-pulse"
                      "available" -> "bg-amber-500"
                      "scheduled" -> "bg-gray-400"
                      "retryable" -> "bg-red-400"
                      _ -> "bg-gray-400"
                    end
                  ]}></span>
                  <span class="font-mono text-xs text-gray-900 dark:text-gray-100">
                    <%= job.short_worker %>
                  </span>
                  <span class="text-xs text-gray-500 dark:text-gray-400">
                    <%= job.queue %>
                  </span>
                  <%= if job.args["mode"] do %>
                    <span class="text-xs px-1.5 py-0.5 rounded bg-gray-200 dark:bg-gray-700 text-gray-600 dark:text-gray-300">
                      <%= job.args["mode"] %>
                    </span>
                  <% end %>
                  <%= if job.args["from"] do %>
                    <span class="text-xs text-gray-500 dark:text-gray-400 font-mono">
                      <%= job.args["from"] %>...<%= job.args["to"] %>
                    </span>
                  <% end %>
                  <%= if job.args["block_hash"] do %>
                    <span class="text-xs text-gray-500 dark:text-gray-400 font-mono">
                      <%= String.slice(job.args["block_hash"], 0..11) %>...
                    </span>
                  <% end %>
                </div>
                <div class="flex items-center gap-3 text-xs text-gray-500 dark:text-gray-400">
                  <span class={[
                    "px-1.5 py-0.5 rounded",
                    case job.state do
                      "executing" -> "bg-blue-100 text-blue-700 dark:bg-blue-900/50 dark:text-blue-300"
                      "available" -> "bg-amber-100 text-amber-700 dark:bg-amber-900/50 dark:text-amber-300"
                      "scheduled" -> "bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300"
                      "retryable" -> "bg-red-100 text-red-700 dark:bg-red-900/50 dark:text-red-300"
                      _ -> "bg-gray-100 text-gray-600"
                    end
                  ]}>
                    <%= job.state %>
                  </span>
                  <%= if job.attempt > 1 do %>
                    <span>
                      attempt <%= job.attempt %>/<%= job.max_attempts %>
                    </span>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Sync Range Form --%>
      <div class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6">
        <h2 class="text-lg font-semibold mb-3 text-gray-900 dark:text-white">
          Sync a Range
        </h2>
        <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
          Fetches headers for missing blocks and queues transaction downloads.
          Safe to re-run — skips what's already synced.
        </p>

        <%= if @form_errors != [] do %>
          <div class="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
            <%= for error <- @form_errors do %>
              <p><%= error %></p>
            <% end %>
          </div>
        <% end %>

        <form phx-submit="start_sync" class="space-y-4">
          <div class="flex gap-4 items-end">
            <div class="flex-1 space-y-2">
              <div class="flex gap-2">
                <label class="flex items-center text-sm">
                  <input
                    type="radio"
                    name="scope_type"
                    value="all"
                    checked={@scope_type == "all"}
                    phx-click="scope_type_changed"
                    class="mr-1"
                  />
                  All
                </label>
                <label class="flex items-center text-sm">
                  <input
                    type="radio"
                    name="scope_type"
                    value="range"
                    checked={@scope_type == "range"}
                    phx-click="scope_type_changed"
                    class="mr-1"
                  />
                  Range
                </label>
                <label class="flex items-center text-sm">
                  <input
                    type="radio"
                    name="scope_type"
                    value="from_block"
                    checked={@scope_type == "from_block"}
                    phx-click="scope_type_changed"
                    class="mr-1"
                  />
                  From height
                </label>
              </div>

              <%= if @scope_type == "range" do %>
                <div class="flex gap-2">
                  <input
                    type="number"
                    name="start_block"
                    placeholder="start"
                    min="0"
                    class="w-32 px-3 py-2 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-sm"
                    required
                  />
                  <input
                    type="number"
                    name="end_block"
                    placeholder="end"
                    min="0"
                    class="w-32 px-3 py-2 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-sm"
                    required
                  />
                </div>
              <% end %>
              <%= if @scope_type == "from_block" do %>
                <input
                  type="number"
                  name="start_block"
                  placeholder="start height"
                  min="0"
                  class="w-32 px-3 py-2 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-sm"
                  required
                />
              <% end %>
            </div>
            <button
              type="submit"
              class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 text-sm font-semibold"
            >
              Sync
            </button>
          </div>
        </form>
      </div>

      <%!-- Database Management (dev only) --%>
      <div
        :if={@dev_mode}
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6"
      >
        <h2 class="text-lg font-semibold mb-3 text-gray-900 dark:text-white">
          Dev Tools
        </h2>
        <div class="flex gap-2">
          <button
            phx-click="clear_blocks"
            data-confirm="Delete all blocks?"
            class="px-3 py-1.5 bg-red-600 text-white rounded hover:bg-red-700 text-sm"
          >
            Clear Blocks
          </button>
          <button
            phx-click="clear_transactions"
            data-confirm="Delete all transactions?"
            class="px-3 py-1.5 bg-red-600 text-white rounded hover:bg-red-700 text-sm"
          >
            Clear Transactions
          </button>
          <button
            phx-click="stop_sync"
            class="px-3 py-1.5 bg-gray-600 text-white rounded hover:bg-gray-700 text-sm"
          >
            Cancel All Jobs
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(number), do: to_string(number)

  # -- Data queries ------------------------------------------------------------

  defp get_block_states do
    import Ecto.Query

    from(b in Bitblocks.Chain.Block,
      group_by: b.sync_state,
      select: {b.sync_state, count(b.id)}
    )
    |> Bitblocks.Repo.all()
    |> Map.new()
  end

  defp get_oban_summary do
    import Ecto.Query

    # Active jobs — show individually
    active_jobs =
      from(j in Oban.Job,
        where: j.state in ["available", "executing", "scheduled", "retryable"],
        order_by: [asc: j.inserted_at],
        limit: 50,
        select: %{
          id: j.id,
          worker: j.worker,
          state: j.state,
          queue: j.queue,
          args: j.args,
          inserted_at: j.inserted_at,
          attempted_at: j.attempted_at,
          attempt: j.attempt,
          max_attempts: j.max_attempts
        }
      )
      |> Bitblocks.Repo.all()
      |> Enum.map(fn job ->
        short_worker = job.worker |> String.split(".") |> List.last()
        Map.put(job, :short_worker, short_worker)
      end)

    # Tip sync specifically
    tip = Enum.any?(active_jobs, fn j ->
      j.worker == "Bitblocks.Workers.SyncHeadersWorker" and
        j.args["mode"] == "tip"
    end)

    %{
      jobs: active_jobs,
      tip: tip,
      headers: Enum.count(active_jobs, &(&1.worker == "Bitblocks.Workers.SyncHeadersWorker")),
      tx_fetch: Enum.count(active_jobs, &(&1.worker == "Bitblocks.Workers.FetchTransactionsWorker"))
    }
  end
end
