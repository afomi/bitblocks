defmodule BitblocksWeb.BuilderLive do
  use BitblocksWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Transaction Builder",
        # Available UTXOs
        available_utxos: [],
        utxo_addresses: "",

        # Selected inputs
        selected_inputs: [],

        # Outputs
        outputs: [
          %{id: generate_id(), type: :payment, address: "", amount: 0},
          %{id: generate_id(), type: :change, address: "", amount: 0}
        ],

        # Transaction
        raw_transaction: nil,
        built_transaction: nil,

        # Signing
        private_keys: %{},

        # State
        loading: false,
        error: nil,
        broadcast_result: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("load_utxos", %{"addresses" => addresses}, socket) do
    # Parse addresses (comma or newline separated)
    parsed_addresses =
      addresses
      |> String.split([",", "\n"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # TODO: Fetch UTXOs from Bitcoin node for these addresses
    # For now, show placeholder structure
    utxos = []

    error_message =
      if parsed_addresses == [] do
        "Enter at least one address to load UTXOs"
      else
        "UTXO fetching not yet implemented - connect to Bitcoin node"
      end

    {:noreply,
     socket
     |> assign(:utxo_addresses, addresses)
     |> assign(:available_utxos, utxos)
     |> assign(:error, error_message)}
  end

  @impl true
  def handle_event("select_utxo", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    utxo = Enum.at(socket.assigns.available_utxos, index)

    if utxo do
      selected_inputs = [utxo | socket.assigns.selected_inputs]
      {:noreply, assign(socket, :selected_inputs, selected_inputs) |> recalculate_transaction()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_input", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    selected_inputs = List.delete_at(socket.assigns.selected_inputs, index)

    {:noreply, assign(socket, :selected_inputs, selected_inputs) |> recalculate_transaction()}
  end

  @impl true
  def handle_event("add_output", %{"type" => type}, socket) do
    new_output = %{
      id: generate_id(),
      type: String.to_atom(type),
      address: "",
      amount: 0,
      data: nil
    }

    outputs = socket.assigns.outputs ++ [new_output]
    {:noreply, assign(socket, :outputs, outputs) |> recalculate_transaction()}
  end

  @impl true
  def handle_event("remove_output", %{"id" => id}, socket) do
    outputs = Enum.reject(socket.assigns.outputs, &(&1.id == id))
    {:noreply, assign(socket, :outputs, outputs) |> recalculate_transaction()}
  end

  @impl true
  def handle_event("update_output", %{"id" => id, "field" => field, "value" => value}, socket) do
    outputs =
      Enum.map(socket.assigns.outputs, fn output ->
        if output.id == id do
          case field do
            "address" -> %{output | address: value}
            "amount" -> %{output | amount: parse_amount(value)}
            "data" -> %{output | data: value}
            _ -> output
          end
        else
          output
        end
      end)

    {:noreply, assign(socket, :outputs, outputs) |> recalculate_transaction()}
  end

  @impl true
  def handle_event("add_private_key", %{"address" => address, "key" => key}, socket) do
    private_keys = Map.put(socket.assigns.private_keys, address, key)
    {:noreply, assign(socket, :private_keys, private_keys)}
  end

  @impl true
  def handle_event("build_transaction", _params, socket) do
    case build_transaction(socket.assigns) do
      {:ok, raw_tx} ->
        {:noreply,
         socket
         |> assign(:raw_transaction, raw_tx)
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("broadcast_transaction", _params, socket) do
    if socket.assigns.raw_transaction do
      with {:ok, txid} <- broadcast_transaction(socket.assigns.raw_transaction) do
        {:noreply,
         socket
         |> assign(:broadcast_result, {:ok, txid})
         |> assign(:error, nil)}
      else
        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:broadcast_result, nil)
           |> assign(:error, "Broadcast failed: #{reason}")}

        other ->
          {:noreply,
           socket
           |> assign(:broadcast_result, nil)
           |> assign(:error, "Broadcast returned unexpected result: #{inspect(other)}")}
      end
    else
      {:noreply,
       socket
       |> assign(:broadcast_result, nil)
       |> assign(:error, "No transaction to broadcast")}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp parse_amount(value) when is_binary(value) do
    case Float.parse(value) do
      # Convert BSV to satoshis
      {amount, _} -> trunc(amount * 100_000_000)
      :error -> 0
    end
  end

  defp parse_amount(value) when is_integer(value), do: value
  defp parse_amount(_), do: 0

  defp recalculate_transaction(socket) do
    # Recalculate change amount based on inputs and outputs
    total_input =
      Enum.reduce(socket.assigns.selected_inputs, 0, fn input, acc ->
        acc + (input[:satoshis] || 0)
      end)

    total_output =
      socket.assigns.outputs
      |> Enum.reject(&(&1.type == :change))
      |> Enum.reduce(0, fn output, acc -> acc + output.amount end)

    # Update change output
    outputs =
      Enum.map(socket.assigns.outputs, fn output ->
        if output.type == :change do
          # Simplified: actual implementation would account for fees
          # 500 sat fee estimate
          change_amount = max(0, total_input - total_output - 500)
          %{output | amount: change_amount}
        else
          output
        end
      end)

    assign(socket, :outputs, outputs)
  end

  defp build_transaction(%{selected_inputs: []}) do
    {:error, "Add at least one input before building a transaction"}
  end

  defp build_transaction(%{outputs: outputs}) when outputs == [] do
    {:error, "Add at least one output before building a transaction"}
  end

  defp build_transaction(assigns) do
    try do
      inputs =
        assigns.selected_inputs
        |> Enum.map(fn input ->
          input
          |> Map.take([:txid, :vout, :satoshis, :script])
          |> Map.update(:satoshis, 0, &(&1 || 0))
        end)

      outputs =
        assigns.outputs
        |> Enum.map(fn output ->
          output
          |> Map.take([:id, :type, :address, :amount, :data])
        end)

      estimated_fee = 500

      # Build a lightweight summary to stand in for raw transaction hex
      tx_summary = %{
        version: 1,
        inputs: inputs,
        outputs: outputs,
        estimated_fee: estimated_fee
      }

      raw_tx =
        tx_summary
        |> Jason.encode!()
        |> Base.encode16(case: :lower)

      {:ok, raw_tx}
    rescue
      error ->
        {:error, "Failed to build transaction: #{Exception.message(error)}"}
    end
  end

  defp broadcast_transaction(_raw_tx) do
    # TODO: Broadcast to Bitcoin node
    {:error, "Broadcasting not yet implemented"}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-full">
      <h1 class="text-4xl font-bold mb-6">
        Transaction Builder
      </h1>

      <div class="bg-blue-50 border-l-4 border-blue-500 p-4 mb-6">
        <div class="flex items-start">
          <div class="flex-shrink-0">
            <svg
              class="h-5 w-5 text-blue-500"
              fill="currentColor"
              viewBox="0 0 20 20"
            >
              <path
                fill-rule="evenodd"
                d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
                clip-rule="evenodd"
              />
            </svg>
          </div>
          <div class="ml-3">
            <p class="text-sm text-blue-700">
              <strong>Build Bitcoin SV Transactions:</strong> Select UTXOs as inputs, configure outputs (payments, change, OP_RETURN data), sign with private keys, and broadcast to the network.
            </p>
          </div>
        </div>
      </div>

      <%!-- Error Display --%>
      <%= if @error do %>
        <div class="bg-red-50 border border-red-200 rounded-lg p-4 mb-6">
          <p class="text-red-700">
            <%= @error %>
          </p>
        </div>
      <% end %>

      <%!-- Success Display --%>
      <%= if @broadcast_result do %>
        <%= case @broadcast_result do %>
          <% {:ok, txid} -> %>
            <div class="bg-green-50 border border-green-200 rounded-lg p-4 mb-6">
              <p class="text-green-700 mb-2">
                <strong>Transaction Broadcast Successfully!</strong>
              </p>
              <div class="font-mono text-xs bg-white p-2 rounded">
                <%= txid %>
              </div>
              <a
                href={"/transactions/#{txid}"}
                class="text-blue-600 hover:underline text-sm mt-2 inline-block"
              >
                View Transaction →
              </a>
            </div>
        <% end %>
      <% end %>

      <%!-- Multi-Column Layout --%>
      <div class="grid grid-cols-4 gap-4">
        <%!-- Column 1: Available UTXOs --%>
        <div class="bg-white shadow-md rounded-lg p-6">
          <h2 class="text-xl font-semibold mb-4">
            Available UTXOs
          </h2>

          <div class="mb-4">
            <label
              for="utxo-addresses"
              class="block text-sm font-medium text-gray-700 mb-2"
            >
              Load UTXOs for addresses
            </label>
            <form phx-submit="load_utxos">
              <textarea
                name="addresses"
                id="utxo-addresses"
                placeholder="Enter addresses (one per line)"
                class="w-full px-3 py-2 border border-gray-300 rounded text-sm font-mono mb-2"
                rows="3"
              ><%= @utxo_addresses %></textarea>
              <button
                type="submit"
                class="w-full px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 text-sm"
              >
                Load UTXOs
              </button>
            </form>
          </div>

          <div class="space-y-2 max-h-96 overflow-y-auto">
            <%= if length(@available_utxos) == 0 do %>
              <p class="text-sm text-gray-500 italic">
                No UTXOs loaded. Enter addresses above to load.
              </p>
            <% else %>
              <%= for {utxo, index} <- Enum.with_index(@available_utxos) do %>
                <div class="border border-gray-200 rounded p-3 hover:bg-gray-50">
                  <div class="flex items-center justify-between mb-2">
                    <span class="text-xs font-semibold text-gray-700">
                      <%= utxo.satoshis / 100_000_000 %> BSV
                    </span>
                    <button
                      phx-click="select_utxo"
                      phx-value-index={index}
                      class="text-xs px-2 py-1 bg-blue-600 text-white rounded hover:bg-blue-700"
                    >
                      Select
                    </button>
                  </div>
                  <div class="text-xs font-mono text-gray-500 break-all">
                    <%= String.slice(utxo.txid, 0, 16) %>...:<%= utxo.vout %>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <%!-- Column 2: Selected Inputs --%>
        <div class="bg-white shadow-md rounded-lg p-6">
          <h2 class="text-xl font-semibold mb-4">
            Inputs
          </h2>

          <div class="space-y-2 mb-4">
            <%= if length(@selected_inputs) == 0 do %>
              <p class="text-sm text-gray-500 italic">
                No inputs selected. Select UTXOs from the left.
              </p>
            <% else %>
              <%= for {input, index} <- Enum.with_index(@selected_inputs, 1) do %>
                <div class="border border-gray-200 rounded p-3">
                  <div class="flex items-center justify-between mb-2">
                    <span class="text-xs font-semibold text-gray-700">
                      Input #<%= index %>
                    </span>
                    <button
                      phx-click="remove_input"
                      phx-value-index={index}
                      class="text-xs px-2 py-1 bg-red-600 text-white rounded hover:bg-red-700"
                    >
                      Remove
                    </button>
                  </div>
                  <div class="text-xs mb-1">
                    <span class="font-semibold">
                      <%= input.satoshis / 100_000_000 %> BSV
                    </span>
                  </div>
                  <div class="text-xs font-mono text-gray-500 break-all">
                    <%= String.slice(input.txid, 0, 16) %>...:<%= input.vout %>
                  </div>

                  <%!-- Private Key Input --%>
                  <div class="mt-2">
                    <label
                      for={"private-key-#{index}"}
                      class="block text-xs font-medium text-gray-700 mb-1"
                    >
                      Private key (WIF)
                    </label>
                    <input
                      type="text"
                      name={"private_key_#{index}"}
                      id={"private-key-#{index}"}
                      placeholder="Private key (WIF)"
                      phx-blur="add_private_key"
                      phx-value-address={input.address}
                      class="w-full px-2 py-1 border border-gray-300 rounded text-xs font-mono"
                    />
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>

          <div class="border-t pt-4">
            <div class="text-sm font-semibold mb-1">
              Total Input:
            </div>
            <div class="text-lg font-bold text-green-700">
              <%= Enum.reduce(@selected_inputs, 0, fn i, acc -> acc + (i[:satoshis] || 0) end) / 100_000_000 %> BSV
            </div>
          </div>
        </div>

        <%!-- Column 3: Outputs --%>
        <div class="bg-white shadow-md rounded-lg p-6">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-xl font-semibold">
              Outputs
            </h2>
            <div class="flex gap-1">
              <button
                phx-click="add_output"
                phx-value-type="payment"
                class="text-xs px-2 py-1 bg-green-700 text-white rounded hover:bg-green-800"
              >
                + Payment
              </button>
              <button
                phx-click="add_output"
                phx-value-type="op_return"
                class="text-xs px-2 py-1 bg-purple-600 text-white rounded hover:bg-purple-700"
              >
                + OP_RETURN
              </button>
            </div>
          </div>

          <div class="space-y-3 max-h-96 overflow-y-auto">
            <%= for {output, index} <- Enum.with_index(@outputs, 1) do %>
              <div class="border border-gray-200 rounded p-3">
                <div class="flex items-center justify-between mb-2">
                  <span class={[
                    "text-xs font-semibold px-2 py-1 rounded",
                    case output.type do
                      :payment -> "bg-green-100 text-green-700"
                      :change -> "bg-blue-100 text-blue-700"
                      :op_return -> "bg-purple-100 text-purple-700"
                    end
                  ]}>
                    <%= String.upcase(to_string(output.type)) %>
                  </span>
                  <%= if output.type != :change do %>
                    <button
                      phx-click="remove_output"
                      phx-value-id={output.id}
                      class="text-xs px-2 py-1 bg-red-600 text-white rounded hover:bg-red-700"
                    >
                      Remove
                    </button>
                  <% end %>
                </div>

                <%= if output.type != :op_return do %>
                  <label
                    for={"output-address-#{index}"}
                    class="block text-xs font-medium text-gray-700 mb-1"
                  >
                    Output address
                  </label>
                  <input
                    type="text"
                    name={"output_address_#{index}"}
                    id={"output-address-#{index}"}
                    placeholder="Address"
                    value={output.address}
                    phx-blur="update_output"
                    phx-value-id={output.id}
                    phx-value-field="address"
                    class="w-full px-2 py-1 border border-gray-300 rounded text-xs font-mono mb-2"
                    disabled={output.type == :change}
                  />
                  <label
                    for={"output-amount-#{index}"}
                    class="block text-xs font-medium text-gray-700 mb-1"
                  >
                    Output amount (BSV)
                  </label>
                  <input
                    type="text"
                    name={"output_amount_#{index}"}
                    id={"output-amount-#{index}"}
                    placeholder="Amount (BSV)"
                    value={if output.amount > 0, do: output.amount / 100_000_000, else: ""}
                    phx-blur="update_output"
                    phx-value-id={output.id}
                    phx-value-field="amount"
                    class="w-full px-2 py-1 border border-gray-300 rounded text-xs"
                    disabled={output.type == :change}
                  />
                  <%= if output.type == :change do %>
                    <p class="text-xs text-gray-500 mt-1">
                      Auto-calculated change
                    </p>
                  <% end %>
                <% else %>
                  <label
                    for={"output-data-#{index}"}
                    class="block text-xs font-medium text-gray-700 mb-1"
                  >
                    OP_RETURN data
                  </label>
                  <textarea
                    placeholder="OP_RETURN data (text or hex)"
                    name={"output_data_#{index}"}
                    id={"output-data-#{index}"}
                    value={output.data || ""}
                    phx-blur="update_output"
                    phx-value-id={output.id}
                    phx-value-field="data"
                    class="w-full px-2 py-1 border border-gray-300 rounded text-xs font-mono"
                    rows="3"
                  ></textarea>
                  <p class="text-xs text-gray-500 mt-1">
                    See <a
                      href="/protocols"
                      class="text-blue-600 hover:underline"
                    >/protocols</a> for formats
                  </p>
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="border-t pt-4 mt-4">
            <div class="text-sm font-semibold mb-1">
              Total Output:
            </div>
            <div class="text-lg font-bold text-red-600">
              <%= Enum.reduce(@outputs, 0, fn o, acc -> acc + o.amount end) / 100_000_000 %> BSV
            </div>
          </div>
        </div>

        <%!-- Column 4: Raw Transaction & Broadcast --%>
        <div class="bg-white shadow-md rounded-lg p-6">
          <h2 class="text-xl font-semibold mb-4">
            Transaction
          </h2>

          <button
            phx-click="build_transaction"
            class="w-full px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 mb-4"
          >
            Build Transaction
          </button>

          <%= if @raw_transaction do %>
            <div class="mb-4">
              <div class="text-sm font-semibold mb-2">
                Raw Transaction (Hex)
              </div>
              <div class="font-mono text-xs bg-gray-50 p-3 rounded border max-h-64 overflow-y-auto break-all">
                <%= @raw_transaction %>
              </div>
            </div>

            <button
              phx-click="broadcast_transaction"
              class="w-full px-4 py-2 bg-green-700 text-white rounded hover:bg-green-800 font-semibold"
            >
              Broadcast Transaction
            </button>
          <% else %>
            <div class="text-sm text-gray-500 italic mb-4">
              Build a transaction to see the raw hex here
            </div>
          <% end %>

          <%!-- Transaction Summary --%>
          <div class="mt-6 border-t pt-4">
            <div class="text-sm font-semibold mb-3">
              Summary
            </div>
            <div class="space-y-2 text-xs">
              <div class="flex justify-between">
                <span class="text-gray-600">
                  Inputs:
                </span>
                <span class="font-semibold">
                  <%= length(@selected_inputs) %>
                </span>
              </div>
              <div class="flex justify-between">
                <span class="text-gray-600">
                  Outputs:
                </span>
                <span class="font-semibold">
                  <%= length(@outputs) %>
                </span>
              </div>
              <div class="flex justify-between">
                <span class="text-gray-600">
                  Fee (est):
                </span>
                <span class="font-semibold">
                  500 sats
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Help Section --%>
      <div class="mt-8 bg-gray-50 border border-gray-200 rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4">
          How to Use the Transaction Builder
        </h2>

        <div class="grid md:grid-cols-4 gap-4 text-sm">
          <div>
            <div class="font-semibold text-blue-600 mb-2">
              1. Load UTXOs
            </div>
            <p class="text-gray-700">
              Enter Bitcoin addresses to load available UTXOs (unspent transaction outputs) from the blockchain.
            </p>
          </div>

          <div>
            <div class="font-semibold text-blue-600 mb-2">
              2. Select Inputs
            </div>
            <p class="text-gray-700">
              Choose which UTXOs to spend in your transaction. Add private keys (WIF format) for signing.
            </p>
          </div>

          <div>
            <div class="font-semibold text-blue-600 mb-2">
              3. Configure Outputs
            </div>
            <p class="text-gray-700">
              Add payment outputs, OP_RETURN data, or other outputs. Change is calculated automatically.
            </p>
          </div>

          <div>
            <div class="font-semibold text-blue-600 mb-2">
              4. Build & Broadcast
            </div>
            <p class="text-gray-700">
              Build the raw transaction, review it, then broadcast it to the Bitcoin SV network.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
