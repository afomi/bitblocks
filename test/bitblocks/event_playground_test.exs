defmodule Bitblocks.EventPlaygroundTest do
  use ExUnit.Case, async: true

  alias Bitblocks.EventPlayground

  defp unique_address do
    "1event-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  describe "snapshot/1" do
    test "returns empty events and projection for unknown address" do
      address = unique_address()

      assert %{address: ^address, events: [], projection: %{}} =
               EventPlayground.snapshot(address)
    end
  end

  describe "append_event/2" do
    test "appends events and updates projection" do
      address = unique_address()
      object_id = "note/#{address}"

      {:ok, created_event, projection_after_create} =
        EventPlayground.append_event(address, %{
          object_id: object_id,
          event_type: "NoteCreated",
          schema: "com.bitblocks.note/v1",
          payload: %{"title" => "Hello", "body" => "World"}
        })

      assert created_event.event_type == "NoteCreated"
      assert projection_after_create[:title] == "Hello"
      assert projection_after_create[:body] == "World"
      refute projection_after_create[:deleted_at]

      {:ok, updated_event, projection_after_update} =
        EventPlayground.append_event(address, %{
          object_id: object_id,
          event_type: "NoteTitleUpdated",
          schema: "com.bitblocks.note/v1",
          payload: %{"title" => "New Title"}
        })

      assert updated_event.event_number == created_event.event_number + 1
      assert projection_after_update[:title] == "New Title"
      assert projection_after_update[:body] == "World"
    end

    test "broadcasts updates over PubSub" do
      address = unique_address()
      object_id = "note/#{address}"

      :ok = EventPlayground.subscribe(address)

      {:ok, _event, _projection} =
        EventPlayground.append_event(address, %{
          object_id: object_id,
          event_type: "NoteCreated",
          schema: "com.bitblocks.note/v1",
          payload: %{"title" => "Hello", "body" => "World"}
        })

      assert_receive {:address_repo_event,
                      %{
                        address: ^address,
                        event: %{event_type: "NoteCreated"},
                        events: [_],
                        projection: %{title: "Hello"}
                      }},
                     200
    end
  end
end
