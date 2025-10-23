defmodule BitblocksWeb.AddressRepoLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

  defp unique_address do
    "1lv-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp event_params(address, object_id, overrides \\ %{}) do
    Map.merge(
      %{
        "address" => address,
        "object_id" => object_id,
        "event_type" => "NoteCreated",
        "schema" => "com.bitblocks.note/v1",
        "title" => "Hello",
        "body" => "World",
        "txid" => "",
        "metadata" => ""
      },
      overrides
    )
  end

  test "renders snapshot and appends events via form", %{conn: conn} do
    address = unique_address()
    object_id = "note/#{address}"

    {:ok, view, html} = live(conn, "/address_repo?address=#{address}", on_error: :warn)
    assert html =~ "Address Repo Playground"
    assert html =~ address

    view
    |> form("#event-form", %{"event" => event_params(address, object_id)})
    |> render_submit()

    rendered = render(view)

    assert rendered =~ "NoteCreated"
    assert rendered =~ "Hello"
    assert rendered =~ object_id

    view
    |> form("#event-form", %{
      "event" =>
        event_params(address, object_id, %{
          "event_type" => "NoteTitleUpdated",
          "title" => "Renamed"
        })
    })
    |> render_submit()

    rendered_after_update = render(view)

    assert rendered_after_update =~ "NoteTitleUpdated"
    assert rendered_after_update =~ "Renamed"
  end
end
