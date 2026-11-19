defmodule BitblocksWeb.UsageLiveTest do
  @moduledoc """
  The /usage page: admin-gated, shows the measured rollups by class and by
  caller, and switches the window in the URL
  (https://github.com/afomi/bitblocks/issues/61).
  """
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.{ApiKeys, Repo, Usage}
  alias Bitblocks.Usage.Rollup

  describe "access" do
    setup do
      previous = Application.get_env(:bitblocks, :admin_auth)
      Application.put_env(:bitblocks, :admin_auth, enabled: true)
      on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, previous) end)
      :ok
    end

    test "an anonymous visitor is refused", %{conn: conn} do
      conn = get(conn, "/usage")
      refute conn.status == 200
      assert conn.halted
    end
  end

  test "shows usage by class and caller, and switches the window", %{conn: conn} do
    {:ok, key, _token} = ApiKeys.create("live-usage", 60)
    hour = DateTime.utc_now() |> DateTime.truncate(:second) |> Map.merge(%{minute: 0, second: 0})

    Repo.insert!(%Rollup{
      hour: hour,
      caller_kind: "key",
      caller_id: to_string(key.id),
      endpoint_class: "raw_export",
      requests: 1_234,
      response_bytes: 5_000_000,
      db_us: 2_000_000,
      db_queries: 3_000,
      node_calls: 12
    })

    {:ok, view, html} = live(conn, "/usage")

    assert html =~ "nobody is charged"
    assert has_element?(view, "#usage-class-raw_export", "1,234")
    assert has_element?(view, "#usage-caller-key-#{key.id}", "live-usage")
    assert has_element?(view, "#usage-caller-key-#{key.id}", "5.0 MB")

    view |> element("#usage-window-720") |> render_click()
    assert_patch(view, "/usage?hours=720")
    assert Usage.report(hours: 720).hours == 720
  end
end
