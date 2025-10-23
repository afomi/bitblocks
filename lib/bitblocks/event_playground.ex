defmodule Bitblocks.EventPlayground do
  @moduledoc """
  In-memory sandbox that treats a Bitcoin address like a Git repository of events.

  It lets developers append note-flavoured events, projects them into state, and
  broadcasts updates over PubSub so LiveView sessions can stay in sync.
  """

  use GenServer

  alias Bitblocks.EventPlayground.Event
  alias Bitblocks.EventPlayground.NoteProjector
  alias Phoenix.PubSub

  @pubsub Bitblocks.PubSub
  @name __MODULE__

  @type snapshot :: %{
          address: String.t(),
          events: [Event.t()],
          projection: map()
        }

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: @name], opts))
  end

  @spec snapshot(String.t()) :: snapshot
  def snapshot(address) do
    GenServer.call(@name, {:snapshot, normalize_address(address)})
  end

  @spec append_event(String.t(), map()) :: {:ok, Event.t(), map()} | {:error, String.t()}
  def append_event(address, attrs) do
    GenServer.call(@name, {:append, normalize_address(address), attrs})
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(address) do
    PubSub.subscribe(@pubsub, topic(normalize_address(address)))
  end

  @spec topic(String.t()) :: String.t()
  def topic(address) do
    "address_repo:#{normalize_address(address)}"
  end

  ## GenServer callbacks

  @impl true
  def init(_state) do
    {:ok, seed_demo(%{})}
  end

  @impl true
  def handle_call({:snapshot, address}, _from, state) do
    {stream, state} = ensure_stream(state, address)
    projection = project(stream.events)
    {:reply, %{address: address, events: stream.events, projection: projection}, state}
  end

  def handle_call({:append, address, attrs}, _from, state) do
    {stream, state} = ensure_stream(state, address)

    case Event.build(address, attrs, stream.next_event_number) do
      {:ok, event} ->
        events = stream.events ++ [event]
        projection = project(events)
        new_stream = %{stream | events: events, next_event_number: stream.next_event_number + 1}
        new_state = Map.put(state, address, new_stream)

        broadcast(address, %{
          address: address,
          event: event,
          events: events,
          projection: projection
        })

        {:reply, {:ok, event, projection}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  ## Internal helpers

  defp normalize_address(address) when is_binary(address) do
    address |> String.trim()
  end

  defp normalize_address(address), do: to_string(address) |> normalize_address()

  defp ensure_stream(state, address) do
    case Map.fetch(state, address) do
      {:ok, stream} ->
        {stream, state}

      :error ->
        new_stream = %{address: address, events: [], next_event_number: 1}
        {new_stream, Map.put(state, address, new_stream)}
    end
  end

  defp project(events) do
    NoteProjector.apply(events)
  end

  defp broadcast(address, payload) do
    PubSub.broadcast(@pubsub, topic(address), {:address_repo_event, payload})
  end

  defp seed_demo(state) do
    demo_address = normalize_address("1note-demo")

    {:ok, created} =
      Event.build(
        demo_address,
        %{
          object_id: "note/demo",
          event_type: "NoteCreated",
          schema: "com.bitblocks.note/v1",
          payload: %{"title" => "Demo note", "body" => "Change me live"}
        },
        1
      )

    {:ok, updated} =
      Event.build(
        demo_address,
        %{
          object_id: "note/demo",
          event_type: "NoteTitleUpdated",
          schema: "com.bitblocks.note/v1",
          payload: %{"title" => "Demo note (edited)"}
        },
        2
      )

    stream = %{
      address: demo_address,
      events: [created, updated],
      next_event_number: 3
    }

    Map.put(state, demo_address, stream)
  end
end
