defmodule BitblocksWeb.AddressRepoLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.EventPlayground

  @default_address "1note-demo"

  @impl true
  def mount(params, _session, socket) do
    address = params |> Map.get("address", @default_address) |> String.trim()
    object_id = params |> Map.get("object_id") |> default_object_id(address)
    base_form = base_event_form(address, object_id)

    socket =
      socket
      |> assign(
        page_title: "Address Repo Playground",
        address: address,
        address_input: address,
        events: [],
        projection: %{},
        event_form: base_form,
        flash_message: nil,
        error_message: nil,
        subscribed_addresses: MapSet.new()
      )
      |> assign_snapshot(address)

    socket =
      if connected?(socket) do
        socket
        |> ensure_subscription(address)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("switch-address", %{"address" => address_param}, socket) do
    address = String.trim(address_param)
    socket = ensure_subscription(socket, address)

    socket =
      socket
      |> assign(address: address, address_input: address)
      |> assign_snapshot(address)
      |> assign(event_form: base_event_form(address, default_object_id(address)))
      |> clear_messages()

    {:noreply, socket}
  end

  def handle_event("update-event", %{"event" => params}, socket) do
    event_form = Map.merge(socket.assigns.event_form, params)
    {:noreply, assign(socket, event_form: event_form) |> clear_messages()}
  end

  def handle_event("append-event", %{"event" => params}, socket) do
    socket = clear_messages(socket)

    with {:ok, payload} <- build_payload(params),
         {:ok, _event, _projection} <-
           EventPlayground.append_event(socket.assigns.address, %{
             object_id: params["object_id"],
             event_type: params["event_type"],
             schema: params["schema"],
             payload: payload,
             metadata: params["metadata"],
             txid: params["txid"],
             timestamp: params["timestamp"]
           }) do
      updated_form =
        socket.assigns.event_form
        |> Map.put("txid", "")
        |> Map.put("metadata", "")

      {:noreply,
       socket
       |> assign(event_form: updated_form, flash_message: "Event appended")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error_message: to_string(reason))}
    end
  end

  @impl true
  def handle_info({:address_repo_event, %{address: address} = payload}, socket) do
    if address == socket.assigns.address do
      socket =
        socket
        |> assign(events: payload.events, projection: payload.projection)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  ## Helpers

  defp assign_snapshot(socket, address) do
    snapshot = EventPlayground.snapshot(address)

    socket
    |> assign(events: snapshot.events, projection: snapshot.projection)
    |> update_event_form_object_id(address)
  end

  defp update_event_form_object_id(socket, address) do
    object_id = default_object_id(address)
    assign(socket, event_form: Map.put(socket.assigns.event_form, "object_id", object_id))
  end

  defp ensure_subscription(socket, address) do
    subscriptions = socket.assigns.subscribed_addresses

    if connected?(socket) and not MapSet.member?(subscriptions, address) do
      :ok = EventPlayground.subscribe(address)
      assign(socket, subscribed_addresses: MapSet.put(subscriptions, address))
    else
      socket
    end
  end

  defp default_object_id(nil, address) do
    default_object_id(address)
  end

  defp default_object_id("", address) do
    default_object_id(address)
  end

  defp default_object_id(object_id, _address) when is_binary(object_id) and object_id != "" do
    object_id
  end

  defp default_object_id(nil), do: "note/#{@default_address}"

  defp default_object_id(address) when is_binary(address) and address != "" do
    trimmed = String.replace(address, ~r/[^a-zA-Z0-9]/, "")
    "note/#{String.slice(trimmed, 0, 16)}"
  end

  defp base_event_form(address, object_id) do
    %{
      "address" => address,
      "object_id" => object_id,
      "event_type" => "NoteCreated",
      "schema" => "com.bitblocks.note/v1",
      "title" => "",
      "body" => "",
      "metadata" => "",
      "txid" => "",
      "timestamp" => ""
    }
  end

  defp clear_messages(socket) do
    assign(socket, flash_message: nil, error_message: nil)
  end

  defp build_payload(%{"event_type" => "NoteCreated"} = params) do
    title = String.trim(params["title"] || "")
    body = String.trim(params["body"] || "")

    if title == "" or body == "" do
      {:error, "title and body required for NoteCreated"}
    else
      {:ok, %{"title" => title, "body" => body}}
    end
  end

  defp build_payload(%{"event_type" => "NoteTitleUpdated"} = params) do
    title = String.trim(params["title"] || "")

    if title == "" do
      {:error, "title required for NoteTitleUpdated"}
    else
      {:ok, %{"title" => title}}
    end
  end

  defp build_payload(%{"event_type" => "NoteBodyUpdated"} = params) do
    body = String.trim(params["body"] || "")

    if body == "" do
      {:error, "body required for NoteBodyUpdated"}
    else
      {:ok, %{"body" => body}}
    end
  end

  defp build_payload(%{"event_type" => "NoteDeleted"} = params) do
    timestamp = String.trim(params["timestamp"] || "")

    payload =
      if timestamp == "" do
        %{}
      else
        %{"timestamp" => timestamp}
      end

    {:ok, payload}
  end

  defp build_payload(%{"event_type" => other}) do
    {:error, "unsupported event_type #{other}"}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="container mx-auto px-6 py-8"
    >
      <h1
        class="text-4xl font-bold mb-6"
      >
        Address Repo Playground
      </h1>

      <div
        class="grid grid-cols-1 lg:grid-cols-2 gap-6"
      >
        <section
          class="bg-white shadow rounded-lg p-6 space-y-6"
        >
          <div>
            <h2
              class="text-xl font-semibold mb-2"
            >
              Target address
            </h2>
            <p
              class="text-sm text-gray-600 mb-4"
            >
              Treat a Bitcoin address as a Git repository. Switch addresses to replay a different history.
            </p>
            <form
              id="address-form"
              class="space-y-3"
              phx-submit="switch-address"
            >
              <label
                class="block text-sm font-medium text-gray-700"
                for="address-input"
              >
                Bitcoin address
              </label>
              <input
                id="address-input"
                name="address"
                type="text"
                class="w-full border border-gray-300 rounded px-3 py-2 font-mono text-sm"
                value={@address_input}
              />
              <button
                type="submit"
                class="w-full bg-blue-600 text-white rounded py-2 hover:bg-blue-700"
              >
                Load history
              </button>
            </form>
            <p
              class="text-xs text-gray-500 mt-2"
            >
              Current object_id default:
              <code
                class="font-mono text-xs"
              >
                <%= @event_form["object_id"] %>
              </code>
            </p>
          </div>

          <div>
            <h2
              class="text-xl font-semibold mb-2"
            >
              Append event
            </h2>
            <p
              class="text-sm text-gray-600 mb-4"
            >
              Submit CRUD-flavoured events to see projections update in real time across all subscribers.
            </p>

            <%= if @flash_message do %>
              <div
                class="border border-green-200 bg-green-50 text-green-800 px-3 py-2 rounded text-sm"
              >
                <%= @flash_message %>
              </div>
            <% end %>

            <%= if @error_message do %>
              <div
                class="border border-red-200 bg-red-50 text-red-800 px-3 py-2 rounded text-sm"
              >
                <%= @error_message %>
              </div>
            <% end %>

            <form
              id="event-form"
              class="space-y-4"
              phx-change="update-event"
              phx-submit="append-event"
            >
              <input
                type="hidden"
                name="event[address]"
                value={@address}
              />

              <div
                class="space-y-2"
              >
                <label
                  class="block text-sm font-medium text-gray-700"
                  for="object-id-input"
                >
                  object_id
                </label>
                <input
                  id="object-id-input"
                  name="event[object_id]"
                  type="text"
                  class="w-full border border-gray-300 rounded px-3 py-2 font-mono text-sm"
                  value={@event_form["object_id"]}
                />
              </div>

              <div
                class="space-y-2"
              >
                <label
                  class="block text-sm font-medium text-gray-700"
                  for="event-type-select"
                >
                  event_type
                </label>
                <select
                  id="event-type-select"
                  name="event[event_type]"
                  class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
                  value={@event_form["event_type"]}
                >
                  <option
                    value="NoteCreated"
                  >
                    NoteCreated
                  </option>
                  <option
                    value="NoteTitleUpdated"
                  >
                    NoteTitleUpdated
                  </option>
                  <option
                    value="NoteBodyUpdated"
                  >
                    NoteBodyUpdated
                  </option>
                  <option
                    value="NoteDeleted"
                  >
                    NoteDeleted
                  </option>
                </select>
              </div>

              <div
                :if={@event_form["event_type"] in ["NoteCreated", "NoteTitleUpdated"]}
                class="space-y-2"
              >
                <label
                  class="block text-sm font-medium text-gray-700"
                  for="title-input"
                >
                  title
                </label>
                <input
                  id="title-input"
                  name="event[title]"
                  type="text"
                  class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
                  value={@event_form["title"]}
                />
              </div>

              <div
                :if={@event_form["event_type"] in ["NoteCreated", "NoteBodyUpdated"]}
                class="space-y-2"
              >
                <label
                  class="block text-sm font-medium text-gray-700"
                  for="body-input"
                >
                  body
                </label>
                <textarea
                  id="body-input"
                  name="event[body]"
                  rows="3"
                  class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
                ><%= @event_form["body"] %></textarea>
              </div>

              <div
                :if={@event_form["event_type"] == "NoteDeleted"}
                class="space-y-2"
              >
                <label
                  class="block text-sm font-medium text-gray-700"
                  for="timestamp-input"
                >
                  deletion timestamp (ISO8601 optional)
                </label>
                <input
                  id="timestamp-input"
                  name="event[timestamp]"
                  type="text"
                  class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
                  value={@event_form["timestamp"]}
                />
              </div>

              <div
                class="space-y-2"
              >
                <label
                  class="block text-sm font-medium text-gray-700"
                  for="schema-input"
                >
                  schema
                </label>
                <input
                  id="schema-input"
                  name="event[schema]"
                  type="text"
                  class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
                  value={@event_form["schema"]}
                />
              </div>

              <div
                class="space-y-2"
              >
                <label
                  class="block text-sm font-medium text-gray-700"
                  for="metadata-input"
                >
                  metadata (key=value per line)
                </label>
                <textarea
                  id="metadata-input"
                  name="event[metadata]"
                  rows="2"
                  class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
                ><%= @event_form["metadata"] %></textarea>
              </div>

              <div
                class="space-y-2"
              >
                <label
                  class="block text-sm font-medium text-gray-700"
                  for="txid-input"
                >
                  txid (optional override)
                </label>
                <input
                  id="txid-input"
                  name="event[txid]"
                  type="text"
                  class="w-full border border-gray-300 rounded px-3 py-2 font-mono text-xs"
                  value={@event_form["txid"]}
                />
              </div>

              <button
                type="submit"
                class="w-full bg-green-600 text-white rounded py-2 hover:bg-green-700"
              >
                Append event
              </button>
            </form>
          </div>
        </section>

        <section
          class="bg-white shadow rounded-lg p-6 space-y-6"
        >
          <div>
            <h2
              class="text-xl font-semibold mb-2"
            >
              Working tree
            </h2>
            <p
              class="text-sm text-gray-600 mb-4"
            >
              Deterministic state derived from the replayed event stream.
            </p>
            <pre
              class="bg-gray-900 text-green-200 text-xs rounded p-4 overflow-auto"
            ><code><%= Jason.encode!(@projection, pretty: true) %></code></pre>
          </div>

          <div>
            <h2
              class="text-xl font-semibold mb-2"
            >
              Commit history
            </h2>
            <ul
              class="space-y-3"
            >
              <%= for event <- Enum.reverse(@events) do %>
                <li
                  class="border border-gray-200 rounded p-3"
                >
                  <div
                    class="flex items-center justify-between text-sm font-semibold"
                  >
                    <span>
                      <%= "##{event.event_number} #{event.event_type}" %>
                    </span>
                    <span
                      class="font-mono text-xs text-gray-500"
                    >
                      <%= event.txid %>
                    </span>
                  </div>
                  <p
                    class="text-xs text-gray-500 mt-1"
                  >
                    object:
                    <code
                      class="font-mono text-xs"
                    >
                      <%= event.object_id %>
                    </code>
                  </p>
                  <pre
                    class="bg-gray-50 text-gray-800 text-xs rounded p-3 mt-2 overflow-auto"
                  ><code><%= Jason.encode!(event.payload, pretty: true) %></code></pre>
                </li>
              <% end %>
            </ul>
          </div>
        </section>
      </div>
    </div>
    """
  end
end
