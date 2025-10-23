defmodule BitblocksWeb.SyncLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.SyncWorker
  alias Phoenix.PubSub

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(Bitblocks.PubSub, "sync_progress")
      PubSub.subscribe(Bitblocks.PubSub, "sync_pipeline")
    end

    status = safe_get_status(SyncWorker)
    pipeline_status = safe_get_pipeline_status()
    chain_tip = get_chain_tip()
    {blocks_count, transactions_count} = get_db_counts()
    sync_jobs = get_recent_sync_jobs()

    socket =
      assign(socket,
        page_title: "Blockchain Sync",
        scope_type: "range",
        sync_mode: "sequential",
        start_block: "",
        end_block: "",
        tx_start_block: "",
        tx_end_block: "",
        sync_status: status,
        pipeline_status: pipeline_status,
        form_errors: [],
        tx_form_errors: [],
        chain_tip: chain_tip,
        blocks_count: blocks_count,
        transactions_count: transactions_count,
        sync_jobs: sync_jobs
      )

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
    blocks = Bitblocks.Repo.aggregate(Bitblocks.Chain.Block, :count, :id)
    transactions = Bitblocks.Repo.aggregate(Bitblocks.Chain.Transaction, :count, :id)
    {blocks, transactions}
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
  def handle_event("sync_mode_changed", %{"value" => sync_mode}, socket) do
    {:noreply, assign(socket, sync_mode: sync_mode, form_errors: [])}
  end

  @impl true
  def handle_event("start_sync", params, socket) do
    require Logger
    Logger.info("SyncLive: Received start_sync event with params: #{inspect(params)}")
    sync_mode = socket.assigns.sync_mode
    Logger.info("SyncLive: Using sync_mode: #{sync_mode}, scope_type: #{socket.assigns.scope_type}")

    case build_scope(socket.assigns.scope_type, params) do
      {:ok, scope} ->
        Logger.info("SyncLive: Built scope: #{inspect(scope)}")
        result =
          case sync_mode do
            "parallel" ->
              Logger.info("SyncLive: Starting parallel sync")
              start_parallel_sync(scope)

            "sequential" ->
              Logger.info("SyncLive: Starting sequential sync")
              case SyncWorker.start_sync(scope) do
                :ok -> :ok
                {:error, :already_running} -> {:error, "Sync is already running"}
                {:error, reason} -> {:error, "Failed to start sync: #{inspect(reason)}"}
              end
          end

        case result do
          :ok ->
            {:noreply, assign(socket, form_errors: [])}

          {:error, message} ->
            {:noreply, assign(socket, form_errors: [message])}
        end

      {:error, errors} ->
        {:noreply, assign(socket, form_errors: errors)}
    end
  end

  @impl true
  def handle_event("stop_sync", _params, socket) do
    # Stop both sync methods
    SyncWorker.stop_sync()
    Bitblocks.Sync.Pipeline.stop_sync()
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_blocks", _params, socket) do
    {count, _} = Bitblocks.Repo.delete_all(Bitblocks.Chain.Block)
    {blocks_count, transactions_count} = get_db_counts()

    socket =
      socket
      |> put_flash(:info, "Deleted #{count} blocks")
      |> assign(blocks_count: blocks_count, transactions_count: transactions_count)

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_transactions", _params, socket) do
    {count, _} = Bitblocks.Repo.delete_all(Bitblocks.Chain.Transaction)
    {blocks_count, transactions_count} = get_db_counts()

    socket =
      socket
      |> put_flash(:info, "Deleted #{count} transactions")
      |> assign(blocks_count: blocks_count, transactions_count: transactions_count)

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "queue_transactions",
        %{"tx_start_block" => start_str, "tx_end_block" => end_str},
        socket
      ) do
    with {start_block, ""} <- Integer.parse(start_str),
         {end_block, ""} <- Integer.parse(end_str),
         true <- start_block >= 0,
         true <- end_block >= start_block do
      with {:ok, count} <-
             Bitblocks.Chain.queue_transaction_fetch_for_range(start_block, end_block) do
        if count > 0 do
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Queued #{count} transaction download jobs for blocks #{start_block}-#{end_block}"
           )
           |> assign(tx_form_errors: [])}
        else
          {:noreply,
           socket
           |> put_flash(
             :info,
             "No blocks found in range #{start_block}-#{end_block} that need transactions. They may already be synced or not exist."
           )
           |> assign(tx_form_errors: [])}
        end
      else
        {:error, reason} ->
          {:noreply, assign(socket, tx_form_errors: ["Failed to queue jobs: #{inspect(reason)}"])}

        other ->
          {:noreply,
           assign(socket, tx_form_errors: ["Unexpected queue response: #{inspect(other)}"])}
      end
    else
      _ ->
        {:noreply,
         assign(socket,
           tx_form_errors: [
             "Invalid block range. Start and end must be valid integers with end >= start."
           ]
         )}
    end
  end

  @impl true
  def handle_info({:sync_progress, _progress}, socket) do
    status = safe_get_status(SyncWorker)
    pipeline_status = safe_get_pipeline_status()
    {blocks_count, transactions_count} = get_db_counts()
    sync_jobs = get_recent_sync_jobs()

    socket =
      assign(socket,
        sync_status: status,
        pipeline_status: pipeline_status,
        blocks_count: blocks_count,
        transactions_count: transactions_count,
        sync_jobs: sync_jobs
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:pipeline_progress, _progress}, socket) do
    pipeline_status = safe_get_pipeline_status()
    {blocks_count, transactions_count} = get_db_counts()

    socket =
      assign(socket,
        pipeline_status: pipeline_status,
        blocks_count: blocks_count,
        transactions_count: transactions_count
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info(:pipeline_started, socket) do
    pipeline_status = safe_get_pipeline_status()
    {:noreply, assign(socket, pipeline_status: pipeline_status)}
  end

  @impl true
  def handle_info(:pipeline_stopped, socket) do
    pipeline_status = safe_get_pipeline_status()
    {:noreply, assign(socket, pipeline_status: pipeline_status)}
  end

  @impl true
  def handle_info(:pipeline_completed, socket) do
    pipeline_status = safe_get_pipeline_status()
    {blocks_count, transactions_count} = get_db_counts()

    socket =
      assign(socket,
        pipeline_status: pipeline_status,
        blocks_count: blocks_count,
        transactions_count: transactions_count
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:block_error, _height, _error}, socket) do
    pipeline_status = safe_get_pipeline_status()
    {:noreply, assign(socket, pipeline_status: pipeline_status)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp build_scope("all", _params) do
    {:ok, {:all}}
  end

  defp build_scope("range", %{"start_block" => start_str, "end_block" => end_str}) do
    with {start_block, ""} <- Integer.parse(start_str),
         {end_block, ""} <- Integer.parse(end_str),
         true <- start_block >= 0,
         true <- end_block >= start_block do
      {:ok, {:range, start_block, end_block}}
    else
      _ ->
        {:error, ["Invalid block range. Start and end must be valid integers with end >= start."]}
    end
  end

  defp build_scope("from_block", %{"start_block" => start_str}) do
    case Integer.parse(start_str) do
      {start_block, ""} when start_block >= 0 ->
        {:ok, {:from_block, start_block}}

      _ ->
        {:error, ["Invalid start block. Must be a valid integer >= 0."]}
    end
  end

  defp build_scope(_, _) do
    {:error, ["Please select a valid sync scope"]}
  end

  defp start_parallel_sync({:range, start_block, end_block}) do
    case Bitblocks.Sync.Pipeline.start_sync(start_block, end_block) do
      :ok -> :ok
      {:error, :already_running} -> {:error, "Pipeline is already running"}
      {:error, reason} -> {:error, "Failed to start pipeline: #{inspect(reason)}"}
    end
  end

  defp start_parallel_sync({:all}) do
    case Bitblocks.RpcCache.get_blockchain_info() do
      %{"blocks" => tip} ->
        case Bitblocks.Sync.Pipeline.start_sync(0, tip) do
          :ok -> :ok
          {:error, :already_running} -> {:error, "Pipeline is already running"}
          {:error, reason} -> {:error, "Failed to start pipeline: #{inspect(reason)}"}
        end

      _ ->
        {:error, "Failed to get blockchain info from node"}
    end
  end

  defp start_parallel_sync({:from_block, start_block}) do
    case Bitblocks.RpcCache.get_blockchain_info() do
      %{"blocks" => tip} ->
        case Bitblocks.Sync.Pipeline.start_sync(start_block, tip) do
          :ok -> :ok
          {:error, :already_running} -> {:error, "Pipeline is already running"}
          {:error, reason} -> {:error, "Failed to start pipeline: #{inspect(reason)}"}
        end

      _ ->
        {:error, "Failed to get blockchain info from node"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="container mx-auto px-4 py-8 max-w-6xl"
    >
      <h1
        class="text-4xl font-bold mb-6 text-gray-900 dark:text-white"
      >
        Blockchain Synchronization
      </h1>

      <%!-- Chain Status Component --%>
      <BitblocksWeb.ChainStatusComponent.chain_status
        chain_tip={@chain_tip}
        blocks_count={@blocks_count}
        transactions_count={@transactions_count}
      />

      <%!-- Database Management --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6"
      >
        <h2
          class="text-2xl font-semibold mb-4 text-gray-900 dark:text-white"
        >
          Database Management
        </h2>
        <div
          class="flex gap-2"
        >
          <button
            phx-click="clear_blocks"
            data-confirm="Are you sure you want to delete all blocks? This cannot be undone."
            class="px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700 font-semibold text-sm"
          >
            Clear Blocks
          </button>
          <button
            phx-click="clear_transactions"
            data-confirm="Are you sure you want to delete all transactions? This cannot be undone."
            class="px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700 font-semibold text-sm"
          >
            Clear Transactions
          </button>
        </div>
      </div>

      <%!-- Current Sync Status --%>
      <%= if @sync_status.status != :idle || @pipeline_status.status != :idle do %>
        <div
          class="bg-white shadow-md rounded-lg p-6 mb-6"
        >
          <h2
            class="text-2xl font-semibold mb-4"
          >
            Current Sync Status
          </h2>

          <div
            class="space-y-4"
          >
            <%!-- Show Pipeline Status if Running --%>
            <%= if @pipeline_status.status == :running do %>
              <div
                class="flex items-center gap-4"
              >
                <span
                  class="font-medium"
                >
                  Mode:
                </span>
                <span
                  class="text-blue-600 font-semibold"
                >
                  Parallel (5 workers)
                </span>
              </div>
            <% end %>

            <%!-- Status Badge --%>
            <div
              class="flex items-center gap-4"
            >
              <span
                class="font-medium"
              >
                Status:
              </span>
              <span class={[
                "px-3 py-1 rounded-full text-sm font-semibold",
                status_class(
                  if(@pipeline_status.status != :idle,
                    do: @pipeline_status.status,
                    else: @sync_status.status
                  )
                )
              ]}>
                <%= status_text(
                  if(@pipeline_status.status != :idle,
                    do: @pipeline_status.status,
                    else: @sync_status.status
                  )
                ) %>
              </span>
            </div>

            <%!-- Scope Info --%>
            <%= if @pipeline_status.status != :idle do %>
              <div
                class="flex items-center gap-4"
              >
                <span
                  class="font-medium"
                >
                  Range:
                </span>
                <span>
                  Blocks <%= @pipeline_status.start_height %> to <%= @pipeline_status.end_height %>
                </span>
              </div>
            <% else %>
              <div
                class="flex items-center gap-4"
              >
                <span
                  class="font-medium"
                >
                  Scope:
                </span>
                <span>
                  <%= scope_description(@sync_status.scope) %>
                </span>
              </div>
            <% end %>

            <%!-- Progress Bar --%>
            <div>
              <div
                class="flex justify-between mb-2"
              >
                <span
                  class="font-medium"
                >
                  Progress
                </span>
                <%= if @pipeline_status.status != :idle do %>
                  <span
                    class="text-sm text-gray-600"
                  >
                    <%= @pipeline_status.blocks_processed || 0 %> / <%= (@pipeline_status.end_height || 0) - (@pipeline_status.start_height || 0) + 1 %> blocks
                    (<%= @pipeline_status.progress_percent || 0 %>%)
                  </span>
                <% else %>
                  <span
                    class="text-sm text-gray-600"
                  >
                    <%= @sync_status.blocks_synced %> / <%= @sync_status.total_blocks %> blocks
                    (<%= progress_percent(@sync_status) %>%)
                  </span>
                <% end %>
              </div>
              <div
                class="w-full bg-gray-200 rounded-full h-6"
              >
                <div
                  class="bg-blue-600 h-6 rounded-full transition-all duration-300"
                  style={
                    if(@pipeline_status.status != :idle,
                      do: "width: #{@pipeline_status.progress_percent || 0}%",
                      else: "width: #{progress_percent(@sync_status)}%"
                    )
                  }
                >
                </div>
              </div>
            </div>

            <%!-- Current Block Info --%>
            <%= if @pipeline_status.status != :idle do %>
              <div
                class="grid grid-cols-2 gap-4 text-sm"
              >
                <div>
                  <span
                    class="font-medium"
                  >
                    Current Height:
                  </span>
                  <%= @pipeline_status.current_height || 0 %>
                </div>
                <div>
                  <span
                    class="font-medium"
                  >
                    Blocks Processed:
                  </span>
                  <%= @pipeline_status.blocks_processed || 0 %>
                </div>
                <div>
                  <span
                    class="font-medium"
                  >
                    Errors:
                  </span>
                  <%= @pipeline_status.errors_count || 0 %>
                </div>
              </div>
            <% else %>
              <div
                class="grid grid-cols-2 gap-4 text-sm"
              >
                <div>
                  <span
                    class="font-medium"
                  >
                    Current Block:
                  </span>
                  <%= @sync_status.current_block %>
                </div>
                <div>
                  <span
                    class="font-medium"
                  >
                    Transactions in Block:
                  </span>
                  <%= @sync_status.current_block_tx_count || 0 %>
                </div>
                <div>
                  <span
                    class="font-medium"
                  >
                    Errors:
                  </span>
                  <%= @sync_status.errors_count || 0 %>
                </div>
              </div>
            <% end %>

            <%!-- Stop Button --%>
            <%= if @sync_status.status == :running || @pipeline_status.status == :running do %>
              <button
                phx-click="stop_sync"
                class="px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700"
              >
                Stop Sync
              </button>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Sync Configuration Form --%>
      <div
        class="bg-white shadow-md rounded-lg p-6 mb-6"
      >
        <h2
          class="text-2xl font-semibold mb-4"
        >
          Configure New Block Sync
        </h2>

        <%= if @form_errors != [] do %>
          <div
            class="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4"
          >
            <%= for error <- @form_errors do %>
              <p>
                <%= error %>
              </p>
            <% end %>
          </div>
        <% end %>

        <form
          phx-submit="start_sync"
          class="space-y-6"
        >
          <%!-- Sync Mode Selection --%>
          <div>
            <label
              class="block text-sm font-medium mb-2"
            >
              Sync Mode
            </label>
            <div
              class="space-y-3"
            >
              <label
                class="flex items-center"
              >
                <input
                  type="radio"
                  name="sync_mode"
                  value="parallel"
                  checked={@sync_mode == "parallel"}
                  phx-click="sync_mode_changed"
                  class="mr-2"
                />
                <span
                  class="font-medium"
                >
                  Parallel (Fast)
                </span>
                <span
                  class="ml-2 text-sm text-gray-600"
                >
                  - Uses 5 concurrent workers for faster syncing
                </span>
              </label>
              <label
                class="flex items-center"
              >
                <input
                  type="radio"
                  name="sync_mode"
                  value="sequential"
                  checked={@sync_mode == "sequential"}
                  phx-click="sync_mode_changed"
                  class="mr-2"
                />
                <span
                  class="font-medium"
                >
                  Sequential (Slow)
                </span>
                <span
                  class="ml-2 text-sm text-gray-600"
                >
                  - Processes one block at a time (legacy mode)
                </span>
              </label>
            </div>
          </div>

          <%!-- Scope Selection --%>
          <div>
            <label
              class="block text-sm font-medium mb-2"
            >
              Sync Scope
            </label>
            <div
              class="space-y-3"
            >
              <label
                class="flex items-center"
              >
                <input
                  type="radio"
                  name="scope_type"
                  value="all"
                  checked={@scope_type == "all"}
                  phx-click="scope_type_changed"
                  class="mr-2"
                />
                <span
                  class="font-medium"
                >
                  ALL
                </span>
                <span
                  class="ml-2 text-sm text-gray-600"
                >
                  - Sync entire blockchain from genesis to current tip
                </span>
              </label>

              <label
                class="flex items-center"
              >
                <input
                  type="radio"
                  name="scope_type"
                  value="range"
                  checked={@scope_type == "range"}
                  phx-click="scope_type_changed"
                  class="mr-2"
                />
                <span
                  class="font-medium"
                >
                  Range
                </span>
                <span
                  class="ml-2 text-sm text-gray-600"
                >
                  - Sync specific block range
                </span>
              </label>

              <label
                class="flex items-center"
              >
                <input
                  type="radio"
                  name="scope_type"
                  value="from_block"
                  checked={@scope_type == "from_block"}
                  phx-click="scope_type_changed"
                  class="mr-2"
                />
                <span
                  class="font-medium"
                >
                  From Block to Tip
                </span>
                <span
                  class="ml-2 text-sm text-gray-600"
                >
                  - Sync from specific block to current chain tip (continuous)
                </span>
              </label>
            </div>
          </div>

          <%!-- Block Range Inputs --%>
          <%= if @scope_type == "range" do %>
            <div
              class="grid grid-cols-2 gap-4"
            >
              <div>
                <label
                  class="block text-sm font-medium mb-2"
                >
                  Start Block
                </label>
                <input
                  type="number"
                  name="start_block"
                  placeholder="e.g., 100000"
                  min="0"
                  class="w-full px-3 py-2 border border-gray-300 rounded focus:outline-none focus:ring-2 focus:ring-blue-500"
                  required
                />
              </div>
              <div>
                <label
                  class="block text-sm font-medium mb-2"
                >
                  End Block
                </label>
                <input
                  type="number"
                  name="end_block"
                  placeholder="e.g., 200000"
                  min="0"
                  class="w-full px-3 py-2 border border-gray-300 rounded focus:outline-none focus:ring-2 focus:ring-blue-500"
                  required
                />
              </div>
            </div>
          <% end %>

          <%= if @scope_type == "from_block" do %>
            <div>
              <label
                class="block text-sm font-medium mb-2"
              >
                Start Block
              </label>
              <input
                type="number"
                name="start_block"
                placeholder="e.g., 800000"
                min="0"
                class="w-full px-3 py-2 border border-gray-300 rounded focus:outline-none focus:ring-2 focus:ring-blue-500"
                required
              />
              <p
                class="text-sm text-gray-600 mt-1"
              >
                Will continuously sync from this block to the current chain tip
              </p>
            </div>
          <% end %>

          <%!-- Submit Button --%>
          <button
            type="submit"
            disabled={@sync_status.status == :running || @pipeline_status.status == :running}
            class={[
              "px-6 py-3 rounded font-semibold",
              if(@sync_status.status == :running || @pipeline_status.status == :running,
                do: "bg-gray-400 text-gray-700 cursor-not-allowed",
                else: "bg-blue-600 text-white hover:bg-blue-700"
              )
            ]}
          >
            <%= if @sync_status.status == :running || @pipeline_status.status == :running,
              do: "Sync In Progress...",
              else: "Start Sync" %>
          </button>
        </form>
      </div>

      <%!-- Transaction Sync Form --%>
      <div
        class="bg-white shadow-md rounded-lg p-6 mb-6"
      >
        <h2
          class="text-2xl font-semibold mb-4"
        >
          Queue Transaction Downloads
        </h2>

        <p
          class="text-sm text-gray-600 mb-4"
        >
          Download transactions for blocks that have been synced but don't have transaction data yet. Only blocks in "header_synced" state will be queued.
        </p>

        <%= if @tx_form_errors != [] do %>
          <div
            class="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4"
          >
            <%= for error <- @tx_form_errors do %>
              <p>
                <%= error %>
              </p>
            <% end %>
          </div>
        <% end %>

        <form
          phx-submit="queue_transactions"
          class="space-y-4"
        >
          <div
            class="grid grid-cols-2 gap-4"
          >
            <div>
              <label
                class="block text-sm font-medium mb-2"
              >
                Start Block
              </label>
              <input
                type="number"
                name="tx_start_block"
                placeholder="e.g., 1"
                min="0"
                class="w-full px-3 py-2 border border-gray-300 rounded focus:outline-none focus:ring-2 focus:ring-blue-500"
                required
              />
            </div>
            <div>
              <label
                class="block text-sm font-medium mb-2"
              >
                End Block
              </label>
              <input
                type="number"
                name="tx_end_block"
                placeholder="e.g., 50"
                min="0"
                class="w-full px-3 py-2 border border-gray-300 rounded focus:outline-none focus:ring-2 focus:ring-blue-500"
                required
              />
            </div>
          </div>

          <button
            type="submit"
            class="px-6 py-3 bg-green-700 text-white rounded hover:bg-green-800 font-semibold"
          >
            Queue Transaction Downloads
          </button>
        </form>
      </div>

      <%!-- Sync Job History --%>
      <%= if @sync_jobs != [] do %>
        <div
          class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mt-6"
        >
          <h2
            class="text-2xl font-semibold mb-4 text-gray-900 dark:text-white"
          >
            Recent Sync Jobs
          </h2>
          <div
            class="overflow-x-auto"
          >
            <table
              class="min-w-full divide-y divide-gray-200 dark:divide-gray-700"
            >
              <thead
                class="bg-gray-50 dark:bg-gray-900"
              >
                <tr>
                  <th
                    class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                  >
                    Scope
                  </th>
                  <th
                    class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                  >
                    Range
                  </th>
                  <th
                    class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                  >
                    Progress
                  </th>
                  <th
                    class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                  >
                    Status
                  </th>
                  <th
                    class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                  >
                    Started
                  </th>
                  <th
                    class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                  >
                    Duration
                  </th>
                </tr>
              </thead>
              <tbody
                class="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700"
              >
                <%= for job <- @sync_jobs do %>
                  <tr>
                    <td
                      class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                    >
                      <%= job.scope %>
                    </td>
                    <td
                      class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                    >
                      <%= format_number(job.start_block) %> - <%= format_number(job.end_block) %>
                    </td>
                    <td
                      class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                    >
                      <%= format_number(job.blocks_synced) %> / <%= format_number(job.total_blocks) %>
                      <span
                        class="text-xs text-gray-500 dark:text-gray-400"
                      >
                        (<%= job_progress_percent(job) %>%)
                      </span>
                      <%= if job.errors_count && job.errors_count > 0 do %>
                        <span
                          class="ml-2 text-xs text-red-600 dark:text-red-400"
                        >
                          <%= job.errors_count %> errors
                        </span>
                      <% end %>
                    </td>
                    <td
                      class="px-6 py-4 whitespace-nowrap"
                    >
                      <span class={[
                        "px-2 inline-flex text-xs leading-5 font-semibold rounded-full",
                        job_status_class(job.status)
                      ]}>
                        <%= job.status %>
                      </span>
                    </td>
                    <td
                      class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                    >
                      <%= format_datetime(job.started_at) %>
                    </td>
                    <td
                      class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                    >
                      <%= format_duration(job) %>
                    </td>
                  </tr>
                  <%= if job.error_message do %>
                    <tr>
                      <td
                        colspan="6"
                        class="px-6 py-3 bg-red-50 dark:bg-red-900/20"
                      >
                        <div
                          class="text-sm text-red-800 dark:text-red-200"
                        >
                          <strong
                            class="font-semibold"
                          >
                            Errors:
                          </strong>
                          <pre
                            class="mt-1 whitespace-pre-wrap font-mono text-xs"
                          ><%= job.error_message %></pre>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>

      <%!-- Info Box --%>
      <div
        class="bg-blue-50 border border-blue-200 rounded-lg p-6 mt-6"
      >
        <h3
          class="text-xl font-semibold mb-2"
        >
          About Blockchain Sync
        </h3>
        <ul
          class="list-disc list-inside space-y-1 text-sm"
        >
          <li>
            Each block download includes the block metadata and all its transactions
          </li>
          <li>
            Blocks with more transactions will take longer to sync
          </li>
          <li>
            The progress bar shows real-time sync status
          </li>
          <li>
            You can view synced data on the
            <.link
              navigate={~p"/blocks"}
              class="text-blue-600 hover:underline"
            >
              Blocks
            </.link> and
            <.link
              navigate={~p"/transactions"}
              class="text-blue-600 hover:underline"
            >
              Transactions
            </.link> pages
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp status_class(:idle), do: "bg-gray-200 text-gray-800"
  defp status_class(:running), do: "bg-blue-100 text-blue-800"
  defp status_class(:stopped), do: "bg-yellow-100 text-yellow-800"
  defp status_class(:completed), do: "bg-green-100 text-green-800"

  defp status_text(:idle), do: "Idle"
  defp status_text(:running), do: "Running"
  defp status_text(:stopped), do: "Stopped"
  defp status_text(:completed), do: "Completed"

  defp scope_description({:all}), do: "All blocks (0 to chain tip)"

  defp scope_description({:range, start_block, end_block}),
    do: "Blocks #{start_block} to #{end_block}"

  defp scope_description({:from_block, start_block}),
    do: "From block #{start_block} to chain tip (continuous)"

  defp scope_description(_), do: "Unknown"

  defp progress_percent(%{total_blocks: 0}), do: 0
  defp progress_percent(%{total_blocks: nil}), do: 0
  defp progress_percent(%{blocks_synced: nil}), do: 0

  defp progress_percent(%{blocks_synced: synced, total_blocks: total})
       when is_number(synced) and is_number(total) and total > 0 do
    (synced / total * 100) |> Float.round(2)
  end

  defp progress_percent(_), do: 0

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(number), do: to_string(number)

  defp get_recent_sync_jobs do
    import Ecto.Query

    Bitblocks.Repo.all(
      from s in Bitblocks.Chain.SyncJob,
        order_by: [desc: s.started_at],
        limit: 10
    )
  end

  defp safe_get_status(worker) do
    try do
      GenServer.call(worker, :get_status, 30_000)
    catch
      :exit, {:timeout, _} ->
        %{status: :idle, blocks_synced: 0, total_blocks: 0, current_block: 0, errors_count: 0}

      :exit, {:noproc, _} ->
        %{status: :idle, blocks_synced: 0, total_blocks: 0, current_block: 0, errors_count: 0}

      kind, reason ->
        require Logger
        Logger.warning("Failed to get sync status: #{inspect(kind)}, #{inspect(reason)}")
        %{status: :idle, blocks_synced: 0, total_blocks: 0, current_block: 0, errors_count: 0}
    end
  end

  defp safe_get_pipeline_status do
    try do
      GenServer.call(Bitblocks.Sync.Pipeline, :status, 30_000)
    catch
      :exit, {:timeout, _} ->
        %{
          status: :idle,
          start_height: nil,
          end_height: nil,
          current_height: nil,
          blocks_processed: 0,
          progress_percent: 0.0,
          errors_count: 0
        }

      :exit, {:noproc, _} ->
        %{
          status: :idle,
          start_height: nil,
          end_height: nil,
          current_height: nil,
          blocks_processed: 0,
          progress_percent: 0.0,
          errors_count: 0
        }

      kind, reason ->
        require Logger
        Logger.warning("Failed to get pipeline status: #{inspect(kind)}, #{inspect(reason)}")

        %{
          status: :idle,
          start_height: nil,
          end_height: nil,
          current_height: nil,
          blocks_processed: 0,
          progress_percent: 0.0,
          errors_count: 0
        }
    end
  end

  defp job_progress_percent(%{total_blocks: 0}), do: "0.00"
  defp job_progress_percent(%{total_blocks: nil}), do: "0.00"
  defp job_progress_percent(%{blocks_synced: nil}), do: "0.00"

  defp job_progress_percent(%{blocks_synced: synced, total_blocks: total})
       when is_number(synced) and is_number(total) and total > 0 do
    (synced / total * 100) |> Float.round(2) |> Float.to_string()
  end

  defp job_progress_percent(_), do: "0.00"

  defp job_status_class("running"),
    do: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200"

  defp job_status_class("completed"),
    do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"

  defp job_status_class("stopped"),
    do: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200"

  defp job_status_class("failed"), do: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
  defp job_status_class(_), do: "bg-gray-100 text-gray-800 dark:bg-gray-900 dark:text-gray-200"

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_duration(%{started_at: started_at, completed_at: nil}) do
    # Running job - show elapsed time
    duration_seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)
    format_duration_seconds(duration_seconds)
  end

  defp format_duration(%{started_at: started_at, completed_at: completed_at}) do
    duration_seconds = DateTime.diff(completed_at, started_at, :second)
    format_duration_seconds(duration_seconds)
  end

  defp format_duration_seconds(seconds) when seconds < 60 do
    "#{seconds}s"
  end

  defp format_duration_seconds(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}m #{secs}s"
  end

  defp format_duration_seconds(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    "#{hours}h #{minutes}m #{secs}s"
  end
end
