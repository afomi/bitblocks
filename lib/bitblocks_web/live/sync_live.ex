defmodule BitblocksWeb.SyncLive do
  use BitblocksWeb, :live_view

  # Destructive actions (clear blocks/transactions) are only available in dev/test.
  @dev_mode Application.compile_env(:bitblocks, :env, :prod) != :prod

  @impl true
  def mount(_params, _session, socket) do
    idle_backfill = %{total: 0, completed: 0, remaining: 0, in_flight: 0, tx_jobs: 0, failed: 0, percent: 0.0, state: :idle}

    socket =
      assign(socket,
        page_title: "Blockchain Sync",
        dev_mode: @dev_mode,
        scope_type: "range",
        start_block: "",
        end_block: "",
        tx_start_block: "",
        tx_end_block: "",
        backfill_status: idle_backfill,
        form_errors: [],
        tx_form_errors: [],
        chain_tip: nil,
        blocks_count: 0,
        transactions_count: 0,
        sync_jobs: []
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
             |> assign(form_errors: [])}

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

    {:noreply, put_flash(socket, :info, "Cancelled #{cancelled} sync job(s)")}
  end

  @impl true
  def handle_event("start_tip_sync", _params, socket) do
    case %{"mode" => "tip"}
         |> Bitblocks.Workers.SyncHeadersWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "Tip sync started")}

      {:error, _} ->
        {:noreply, put_flash(socket, :info, "Tip sync already running")}
    end
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

    {:noreply, put_flash(socket, :info, "Stopped tip sync (#{cancelled} job(s) cancelled)")}
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
  def handle_event("start_backfill", _params, socket) do
    chain_tip = get_chain_tip()
    to = if chain_tip, do: chain_tip.blocks, else: 0

    case %{"mode" => "range", "from" => 0, "to" => to}
         |> Bitblocks.Workers.SyncHeadersWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Backfill started: syncing headers + transactions for blocks 0..#{to}")
         |> assign(backfill_status: get_backfill_status())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :info, "Backfill already running.")}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {blocks_count, transactions_count} = get_db_counts()

    socket =
      assign(socket,
        backfill_status: get_backfill_status(),
        chain_tip: get_chain_tip(),
        blocks_count: blocks_count,
        transactions_count: transactions_count,
        sync_jobs: get_recent_sync_jobs()
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info(:poll_status, socket) do
    {blocks_count, transactions_count} = get_db_counts()

    socket =
      assign(socket,
        backfill_status: get_backfill_status(),
        blocks_count: blocks_count,
        transactions_count: transactions_count
      )

    Process.send_after(self(), :poll_status, 10_000)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
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

      <%!-- Database Management (dev only) --%>
      <div
        :if={@dev_mode}
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

      <%!-- Sync Configuration --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6"
      >
        <h2
          class="text-2xl font-semibold mb-4 text-gray-900 dark:text-white"
        >
          Sync Blocks
        </h2>

        <p
          class="text-sm text-gray-600 dark:text-gray-400 mb-4"
        >
          Fetches block headers and queues transaction downloads.
          Fills gaps automatically — safe to re-run.
        </p>

        <%= if @form_errors != [] do %>
          <div
            class="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4"
          >
            <%= for error <- @form_errors do %>
              <p><%= error %></p>
            <% end %>
          </div>
        <% end %>

        <form
          phx-submit="start_sync"
          class="space-y-4"
        >
          <%!-- Scope Selection --%>
          <div class="space-y-2">
            <label class="flex items-center">
              <input
                type="radio"
                name="scope_type"
                value="all"
                checked={@scope_type == "all"}
                phx-click="scope_type_changed"
                class="mr-2"
              />
              <span class="font-medium">All</span>
              <span class="ml-2 text-sm text-gray-600 dark:text-gray-400">
                — genesis to chain tip
              </span>
            </label>
            <label class="flex items-center">
              <input
                type="radio"
                name="scope_type"
                value="range"
                checked={@scope_type == "range"}
                phx-click="scope_type_changed"
                class="mr-2"
              />
              <span class="font-medium">Range</span>
              <span class="ml-2 text-sm text-gray-600 dark:text-gray-400">
                — specific block range
              </span>
            </label>
            <label class="flex items-center">
              <input
                type="radio"
                name="scope_type"
                value="from_block"
                checked={@scope_type == "from_block"}
                phx-click="scope_type_changed"
                class="mr-2"
              />
              <span class="font-medium">From block to tip</span>
            </label>
          </div>

          <%!-- Range Inputs --%>
          <%= if @scope_type == "range" do %>
            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium mb-1">Start Block</label>
                <input
                  type="number"
                  name="start_block"
                  placeholder="0"
                  min="0"
                  class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100"
                  required
                />
              </div>
              <div>
                <label class="block text-sm font-medium mb-1">End Block</label>
                <input
                  type="number"
                  name="end_block"
                  placeholder="100000"
                  min="0"
                  class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100"
                  required
                />
              </div>
            </div>
          <% end %>

          <%= if @scope_type == "from_block" do %>
            <div>
              <label class="block text-sm font-medium mb-1">Start Block</label>
              <input
                type="number"
                name="start_block"
                placeholder="800000"
                min="0"
                class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100"
                required
              />
            </div>
          <% end %>

          <div class="flex gap-3">
            <button
              type="submit"
              class="px-6 py-3 bg-blue-600 text-white rounded hover:bg-blue-700 font-semibold"
            >
              Start Sync
            </button>
            <button
              type="button"
              phx-click="stop_sync"
              class="px-6 py-3 bg-red-600 text-white rounded hover:bg-red-700 font-semibold"
            >
              Stop All
            </button>
          </div>
        </form>
      </div>

      <%!-- Transaction Backfill --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6"
      >
        <h2
          class="text-2xl font-semibold mb-4 text-gray-900 dark:text-white"
        >
          Transaction Backfill
        </h2>

        <p
          class="text-sm text-gray-600 dark:text-gray-400 mb-4"
        >
          Walks every block from 0 to tip, fetching missing transaction data.
          Runs in the background, survives restarts.
          Progress is permanent — completed blocks are never revisited.
        </p>

        <div
          class="bg-gray-50 dark:bg-gray-900 rounded-lg p-4 mb-4"
        >
          <div
            class="grid grid-cols-2 md:grid-cols-3 gap-4 text-sm"
          >
            <div>
              <div class="text-gray-600 dark:text-gray-400">
                Status
              </div>
              <div class="font-semibold">
                <%= case @backfill_status.state do %>
                  <% :running -> %>
                    <span class="text-blue-600">
                      ● Running
                    </span>
                  <% :idle -> %>
                    <span class="text-gray-500">
                      ○ Idle
                    </span>
                  <% :done -> %>
                    <span class="text-green-600">
                      ✓ Complete
                    </span>
                <% end %>
              </div>
            </div>
            <div>
              <div class="text-gray-600 dark:text-gray-400">
                Completed
              </div>
              <div class="font-semibold font-mono text-lg">
                <%= format_number(@backfill_status.completed) %>
                <span class="text-xs text-gray-500 font-normal">
                  / <%= format_number(@backfill_status.total) %>
                </span>
              </div>
            </div>
            <div>
              <div class="text-gray-600 dark:text-gray-400">
                Progress
              </div>
              <div class="font-semibold font-mono text-lg">
                <%= @backfill_status.percent %>%
              </div>
            </div>
          </div>

          <%= if @backfill_status.state == :running do %>
            <div
              class="grid grid-cols-3 gap-4 text-sm mt-3 pt-3 border-t border-gray-200 dark:border-gray-700"
            >
              <div>
                <div class="text-gray-600 dark:text-gray-400">
                  In Flight
                </div>
                <div class="font-semibold font-mono">
                  <%= format_number(@backfill_status.in_flight) %> blocks
                </div>
              </div>
              <div>
                <div class="text-gray-600 dark:text-gray-400">
                  Tx Jobs Queued
                </div>
                <div class="font-semibold font-mono">
                  <%= format_number(@backfill_status.tx_jobs) %>
                </div>
              </div>
              <div>
                <div class="text-gray-600 dark:text-gray-400">
                  Failed
                </div>
                <div class={[
                  "font-semibold font-mono",
                  if(@backfill_status.failed > 0, do: "text-red-600", else: "text-gray-500")
                ]}>
                  <%= format_number(@backfill_status.failed) %>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @backfill_status.remaining > 0 do %>
            <div
              class="mt-3 w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2"
            >
              <div
                class="bg-green-600 h-2 rounded-full transition-all duration-500"
                style={"width: #{@backfill_status.percent}%"}
              >
              </div>
            </div>
          <% end %>
        </div>

        <%= if @backfill_status.state != :running do %>
          <button
            phx-click="start_backfill"
            class="px-6 py-3 bg-green-700 text-white rounded hover:bg-green-800 font-semibold"
          >
            Start Backfill
          </button>
        <% else %>
          <span
            class="text-sm text-gray-500 dark:text-gray-400"
          >
            Backfill is running in the background.
            This page refreshes automatically.
          </span>
        <% end %>
      </div>

      <%!-- Continuous Tip Sync --%>
      <div
        class="bg-white shadow-md rounded-lg p-6 mb-6"
      >
        <h2
          class="text-2xl font-semibold mb-4"
        >
          Continuous Tip Sync
        </h2>

        <p
          class="text-sm text-gray-600 dark:text-gray-400 mb-4"
        >
          Watches the chain tip and syncs new blocks as they're mined.
          Re-checks every 30 seconds.
        </p>

        <div class="flex gap-3">
          <button
            phx-click="start_tip_sync"
            class="px-6 py-3 bg-blue-600 text-white rounded hover:bg-blue-700 font-semibold"
          >
            Start Tip Sync
          </button>
          <button
            phx-click="stop_tip_sync"
            class="px-6 py-3 bg-red-600 text-white rounded hover:bg-red-700 font-semibold"
          >
            Stop Tip Sync
          </button>
        </div>
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

  defp get_backfill_status do
    import Ecto.Query

    total = Bitblocks.StatsCache.blocks_count()

    # One query: count blocks by sync_state category
    state_counts =
      from(b in Bitblocks.Chain.Block,
        group_by: b.sync_state,
        select: {b.sync_state, count(b.id)}
      )
      |> Bitblocks.Repo.all()
      |> Map.new()

    completed = Map.get(state_counts, "completed", 0)
    in_flight = Map.get(state_counts, "txs_syncing", 0) + Map.get(state_counts, "txs_queued", 0)
    failed = Map.get(state_counts, "failed", 0)

    # Is the backfill orchestrator job running?
    orchestrator_running =
      from(j in Oban.Job,
        where: j.worker == "Bitblocks.Workers.BackfillTransactionsWorker",
        where: j.state in ["available", "executing", "scheduled"],
        select: count()
      )
      |> Bitblocks.Repo.one()

    # How many individual tx-fetch jobs are queued/running?
    tx_jobs =
      from(j in Oban.Job,
        where: j.queue == "transactions",
        where: j.state in ["available", "executing", "scheduled"],
        select: count()
      )
      |> Bitblocks.Repo.one()

    remaining = total - completed
    percent = if total > 0, do: Float.round(completed / total * 100, 1), else: 0.0

    state =
      cond do
        orchestrator_running > 0 or tx_jobs > 0 -> :running
        remaining == 0 and total > 0 -> :done
        true -> :idle
      end

    %{
      total: total,
      completed: completed,
      remaining: remaining,
      in_flight: in_flight,
      tx_jobs: tx_jobs,
      failed: failed,
      percent: percent,
      state: state
    }
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
