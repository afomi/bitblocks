defmodule BitblocksWeb.ReorgLiveTest do
  # The LiveView process has to see rows inserted by the test.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.Reorgs
  alias BitblocksWeb.ReorgNotice

  test "a failed reorg query leaves the notice off the page" do
    assert ReorgNotice.current(fn -> raise "relation \"reorgs\" does not exist" end) == nil
  end

  test "the page explains what a reorganization is and what happens", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/reorgs")

    assert html =~ "Chain reorganizations"
    assert html =~ "the branch with the most work"
    assert has_element?(view, "#reorg-what-happens", "confirmation")
    refute html =~ "id=\"reorg-notice\""
  end

  test "the page shows the whitepaper's math, a worked example and the drawing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reorgs")

    assert has_element?(view, "#reorg-math", "Section 11")
    assert has_element?(view, "#reorg-math", "0.2045873")
    assert has_element?(view, "#reorg-math-table", "340 blocks")
    assert has_element?(view, "#reorg-drawing img[src='/images/ink-wash/reorg-fork.webp']")

    assert File.exists?(
             Path.join(:code.priv_dir(:bitblocks), "static/images/ink-wash/reorg-fork.webp")
           )
  end

  test "the page is instructional only: recorded reorgs are not listed", %{conn: conn} do
    {:ok, reorg} =
      Reorgs.record_observed(
        %{fork_height: 654_321, fork_point: 654_311, orphan_count: 10, outcome: "resolved"},
        ~U[2020-01-01 00:00:00Z]
      )

    {:ok, _view, html} = live(conn, ~p"/reorgs")

    refute html =~ "id=\"reorg-#{reorg.id}\""
    refute html =~ "654321"
  end

  test "a page reads the reorg banner once", %{conn: conn} do
    {:ok, _} =
      Reorgs.record_observed(
        %{
          fork_height: 800_030,
          fork_point: nil,
          orphan_count: nil,
          outcome: "needs_attention"
        },
        DateTime.utc_now() |> DateTime.truncate(:second)
      )

    parent = self()
    handler = "reorg-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:bitblocks, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if query =~ "\"reorgs\"" do
          send(parent, :reorg_query)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, _view, html} = live(conn, ~p"/guide")

    assert html =~ "id=\"reorg-notice\""
    assert_receive :reorg_query
    refute_receive :reorg_query, 50
  end

  test "a fresh reorg is announced on other pages", %{conn: conn} do
    {:ok, _} =
      Reorgs.record_observed(
        %{
          fork_height: 800_010,
          fork_point: nil,
          orphan_count: nil,
          outcome: "needs_attention"
        },
        DateTime.utc_now() |> DateTime.truncate(:second)
      )

    {:ok, _view, html} = live(conn, ~p"/guide")

    assert html =~ "id=\"reorg-notice\""
    assert html =~ "800010"
    assert html =~ "A chain reorganization needs a person."
    assert html =~ ~s(href="/reorgs")
  end

  describe "with the gate on, as in production" do
    setup do
      previous = Application.get_env(:bitblocks, :admin_auth)
      Application.put_env(:bitblocks, :admin_auth, enabled: true)
      on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, previous) end)

      {:ok, _} =
        Reorgs.record_observed(
          %{fork_height: 800_020, fork_point: nil, orphan_count: nil, outcome: "needs_attention"},
          DateTime.utc_now() |> DateTime.truncate(:second)
        )

      :ok
    end

    test "a visitor never sees the banner: it is our index, not the network", %{conn: conn} do
      html = conn |> get("/reorgs") |> html_response(200)

      refute html =~ "id=\"reorg-notice\""
      refute html =~ "800020"
    end

    test "an admin sees it, linked to what a reorganization is", %{conn: conn} do
      {:ok, user} =
        Bitblocks.Accounts.upsert_github_user(%Ueberauth.Auth{
          provider: :github,
          uid: 4242,
          info: %Ueberauth.Auth.Info{nickname: "op", name: "op"},
          extra: %Ueberauth.Auth.Extra{raw_info: %{user: %{"id" => 4242, "login" => "op"}}}
        })

      {:ok, _} = Bitblocks.Accounts.set_admin("op", true)

      html =
        conn
        |> init_test_session(%{"user_id" => user.id})
        |> get("/reorgs")
        |> html_response(200)

      assert html =~ "id=\"reorg-notice\""
      assert html =~ "800020"
      assert html =~ "What a reorganization is."
    end
  end
end
