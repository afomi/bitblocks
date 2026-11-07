defmodule BitblocksWeb.StartLiveTest do
  # Writes the shared SyncProgress snapshot, so not async.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures
  import Phoenix.LiveViewTest

  alias Bitblocks.ApiKeys
  alias Bitblocks.ApiKeys.ApiKey
  alias Bitblocks.Chain.MerkleProof
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.SyncProgress
  alias BitblocksWeb.SitemapController
  alias BitblocksWeb.StartLive.{Api, Index}

  @pages ~w(/start /start/api /start/guidance /start/interop)

  # Rexxie #1's mint, from the bundled catalog.
  @mint "52c8ee4935f983b7ce10b84882cb42b30d989a4385eaec1289fafe88325eb53f"

  setup do
    :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()})
    on_exit(fn -> :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()}) end)
    :ok
  end

  defp put_coverage(overview) do
    snapshot = SyncProgress.empty_snapshot()

    :ets.insert(
      SyncProgress,
      {:snapshot, %{snapshot | overview: Map.merge(snapshot.overview, overview)}}
    )
  end

  defp rexxie!(attrs \\ []) do
    Bitblocks.Repo.insert!(
      struct!(
        %Item{
          collection_id: Bitblocks.OrdinalCollections.known()["rexxies"],
          origin: "#{@mint}_3",
          mint_txid: @mint,
          name: "Rexxie #1",
          trace_state: "current"
        },
        attrs
      )
    )
  end

  defp user!(attrs \\ []) do
    id = System.unique_integer([:positive])

    Bitblocks.Repo.insert!(
      struct!(%Bitblocks.Accounts.User{github_id: id, login: "user#{id}"}, attrs)
    )
  end

  defp as(conn, user), do: init_test_session(conn, %{"user_id" => user.id})

  defp with_gate(fun) do
    Application.put_env(:bitblocks, :admin_auth, enabled: true)
    on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, enabled: false) end)
    fun.()
  end

  describe "not published yet" do
    test "every page asks not to be indexed", %{conn: conn} do
      for path <- @pages do
        html = conn |> get(path) |> html_response(200)
        assert html =~ ~s(content="noindex, nofollow")
      end
    end

    test "a signed-out visitor can't reach them", %{conn: conn} do
      previous = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, [])

      Application.put_env(
        :ueberauth,
        Ueberauth.Strategy.Github.OAuth,
        client_id: "id",
        client_secret: "secret"
      )

      on_exit(fn ->
        Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, previous)
      end)

      with_gate(fn ->
        for path <- @pages do
          assert conn |> get(path) |> redirected_to() =~ "/sign-in"
        end
      end)
    end

    test "a signed-in visitor who isn't an admin can't reach them", %{conn: conn} do
      with_gate(fn ->
        for path <- @pages do
          assert conn |> as(user!()) |> get(path) |> response(403)
        end
      end)
    end

    test "an admin can", %{conn: conn} do
      with_gate(fn ->
        for path <- @pages do
          assert conn |> as(user!(admin: true)) |> get(path) |> html_response(200)
        end
      end)
    end

    test "the websocket holds the same line" do
      for path <- @pages do
        %{phoenix_live_view: {_view, _action, _opts, live_session}} =
          Phoenix.Router.route_info(BitblocksWeb.Router, "GET", path, "")

        assert live_session.name == :admin
      end
    end

    test "they aren't in the nav, for anyone", %{conn: conn} do
      with_gate(fn ->
        for viewer <- [nil, user!(), user!(admin: true)], path <- ~w(/ /about) do
          viewer_conn = if viewer, do: as(conn, viewer), else: conn

          refute viewer_conn |> get(path) |> html_response(200) =~ ~s(href="/start)
        end
      end)
    end

    test "the sitemap and robots.txt don't name them" do
      refute Enum.any?(SitemapController.public_paths(), &String.starts_with?(&1, "/start"))
      refute File.read!("priv/static/robots.txt") =~ "/start"
    end
  end

  describe "the path" do
    test "reads coverage from the sync, not the copy", %{conn: conn} do
      put_coverage(%{complete_through: 123_456, our_tip: 987_654})

      {:ok, view, _html} = live(conn, ~p"/start")

      assert has_element?(view, "#start-coverage", "123,456")
      assert has_element?(view, "#start-coverage", "987,654")
    end

    test "leaves coverage out before the sync has a figure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start")
      refute has_element?(view, "#start-coverage")
    end

    test "walks the steps in order, and says what isn't built", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/start")

      steps = Regex.scan(~r/id="(step-[a-z-]+)"/, html, capture: :all_but_first) |> List.flatten()

      assert steps == ~w(
               step-first-request
               step-read-a-transaction
               step-prove-it
               step-sign-in
               step-get-a-key
             )

      for step <- ~w(step-first-request step-read-a-transaction step-prove-it) do
        assert has_element?(view, "##{step}", "Works today, no account needed")
      end

      assert has_element?(view, "#step-get-a-key", "Sign in above")
      refute has_element?(view, "#step-get-a-key", "Coming")
      refute has_element?(view, "#start-get-key")
    end

    test "links to the transaction page with no sign-in warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start")

      assert has_element?(view, "#start-tx-page[href^='/transactions/']")
      refute has_element?(view, "#step-read-a-transaction", "sign")
    end

    test "offers sign-in, and keeps API links for after it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start")

      assert has_element?(view, "#start-sign-in[href*='return_to']")
      refute has_element?(view, "#start-tx-link")
    end

    test "knows a signed-in visitor has done that step", %{conn: conn} do
      {:ok, view, _html} = conn |> as(user!(login: "builder")) |> live(~p"/start")

      assert has_element?(view, "#start-signed-in", "builder")
      assert has_element?(view, "#start-tx-link")
      refute has_element?(view, "#start-sign-in")
    end

    test "the proof it teaches climbs to the root it shows" do
      {txid, index, siblings, root} = Index.proof_parts()

      assert MerkleProof.climb(txid, index, siblings) == root
    end
  end

  describe "getting a key" do
    defp token_on(html) do
      [token] = Regex.run(~r/bbk_[A-Za-z0-9_-]{43}/, html)
      token
    end

    test "a signed-in user with no key reaches a first API call from the page", %{conn: conn} do
      user = user!()
      {:ok, view, _html} = conn |> as(user) |> live(~p"/start")

      html = view |> element("#start-get-key") |> render_click()
      token = token_on(html)

      assert has_element?(view, "#start-new-key", "the one time you'll see it")
      refute has_element?(view, "#start-get-key")

      called =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/v1/blocks")

      assert called.status == 200
      assert get_resp_header(called, "x-ratelimit-limit") == ["60"]
      assert ApiKeys.verify(token).user_id == user.id
    end

    test "the page keeps showing which key they hold, never the key", %{conn: conn} do
      user = user!()
      {:ok, _key, token} = ApiKeys.issue_trial(user)

      {:ok, view, html} = conn |> as(user) |> live(~p"/start")

      refute html =~ token
      assert has_element?(view, "#start-your-key", String.slice(token, 0, 12))
      refute has_element?(view, "#start-get-key")
    end

    test "replacing a key ends the old one", %{conn: conn} do
      user = user!()
      {:ok, _key, old} = ApiKeys.issue_trial(user)
      {:ok, view, _html} = conn |> as(user) |> live(~p"/start")

      new = view |> element("#start-replace-key") |> render_click() |> token_on()

      assert new != old
      assert ApiKeys.verify(old) == nil
      assert ApiKeys.verify(new).user_id == user.id
    end

    test "a user holds one active key, and a trial key has no scopes" do
      user = user!()
      {:ok, key, _token} = ApiKeys.issue_trial(user)

      assert key.scopes == []
      assert {:error, %Ecto.Changeset{}} = ApiKeys.issue_trial(user)
    end

    test "keys can't be turned over without end", %{conn: conn} do
      user = user!()
      {:ok, _key, _token} = ApiKeys.issue_trial(user)
      {:ok, view, _html} = conn |> as(user) |> live(~p"/start")

      for _ <- 1..5, do: render_click(view, "replace_key")
      render_click(view, "replace_key")

      assert has_element?(view, "#start-key-error", "Try again in a minute")
      assert Bitblocks.Repo.aggregate(ApiKey, :count) == 6
    end

    test "a logged-out socket can't take a key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start")

      render_click(view, "get_key")

      assert Bitblocks.Repo.aggregate(ApiKey, :count) == 0
    end
  end

  describe "the examples match the API" do
    test "the status example's fields are in the response", %{conn: conn} do
      body = conn |> get(~p"/api/v1/status") |> json_response(200)

      assert Map.has_key?(body, "status")
      assert Map.has_key?(body["index"], "complete_through")
      assert Map.has_key?(body["index"], "tip")
    end

    test "the transaction example's fields are in the response", %{conn: conn} do
      block = block_fixture()
      tx = transaction_fixture(%{block_height: block.height})

      data = conn |> get(~p"/api/v1/txs/#{tx.txid}") |> json_response(200) |> Map.fetch!("data")

      for key <-
            ~w(txid block_hash block_height version input_count output_count) ++
              ~w(total_output_satoshis) do
        assert Map.has_key?(data, key), "#{key} is on the page but not in the API"
      end
    end
  end

  describe "demos" do
    test "says so when Rexxies aren't indexed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start")

      assert has_element?(view, "#demo-rexxies", "hasn't indexed them yet")
      refute has_element?(view, "#rexxie-strip")
    end

    test "shows Rexxies from the index, with the count it holds", %{conn: conn} do
      rexxie!()

      {:ok, view, _html} = live(conn, ~p"/start")

      assert has_element?(view, "#rexxie-strip img[src='/images/rexxies/1.png']")
      assert has_element?(view, "#demo-rexxies", "minted from block 771,246")
      refute has_element?(view, "#demo-rexxies", "2,222")
    end
  end

  describe "the API reference" do
    test "every endpoint it lists is in the router" do
      for group <- Api.groups(), row <- group.rows do
        info = Phoenix.Router.route_info(BitblocksWeb.Router, row.method, row.path, "")

        assert info != :error, "#{row.method} #{row.path} isn't a route"
      end
    end

    test "every example is an endpoint in the router" do
      for group <- Api.groups(), %{example: example} when is_binary(example) <- group.rows do
        assert Phoenix.Router.route_info(BitblocksWeb.Router, "GET", example, "") != :error
      end
    end

    test "states each endpoint's access truthfully", %{conn: conn} do
      with_gate(fn ->
        for group <- Api.groups(), %{method: "GET", access: :caller} = row <- group.rows do
          assert conn |> get(row.path) |> response(401)
        end

        for group <- Api.groups(), %{access: :open} = row <- group.rows do
          refute get(conn, row.path).status == 401, "#{row.path} asked for a caller"
        end
      end)
    end

    test "shows the limits the rate limiter is configured with", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/api")
      limits = Index.rate_limits()

      assert has_element?(view, "#access-table", "#{limits.anonymous}, per IP")
      assert has_element?(view, "#access-table", "#{limits.signed_in}, per user")
    end
  end

  describe "guidance" do
    test "dates every view and labels it a draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/guidance")

      for {anchor, _title, _line} <- Index.guidance_topics() do
        assert has_element?(view, "##{anchor}")
        assert render(element(view, "##{anchor}")) =~ ~r/\d{4}-\d{2}-\d{2}/
        assert render(element(view, "##{anchor}")) =~ "Draft"
        refute render(element(view, "##{anchor}")) =~ "Our position"
      end
    end

    test "the thesis is a dated draft, in plain words", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/guidance")

      assert has_element?(view, "#payments", "A payment should carry its own proof.")
      assert has_element?(view, "#payments", "2026-11-05")
      assert has_element?(view, "#payments", "Draft")
      assert has_element?(view, "#payments", "without asking a company")
      assert has_element?(view, "#payments", "one SDK and no live wallet")
    end

    test "every view on the page stays a draft, listed or not", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/start/guidance")

      rendered =
        ~r/<section[^>]*id="([a-z-]+)"[^>]*aria-labelledby/
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      listed = Enum.map(Index.guidance_topics(), fn {anchor, _title, _line} -> anchor end)
      assert Enum.sort(rendered) == Enum.sort(listed)

      for anchor <- rendered do
        assert render(element(view, "##{anchor}")) =~ "Draft", "#{anchor} isn't a draft"
      end

      template = File.read!("lib/bitblocks_web/live/start_live/guidance.html.heex")
      views = Regex.scan(~r/<\.view\b.*?>/s, template)
      statuses = Regex.scan(~r/^\s+status="([a-z_]+)"$/m, template, capture: :all_but_first)

      assert length(views) == length(rendered)
      assert length(statuses) == length(views)
      assert Enum.uniq(statuses) == [["draft"]]
    end

    test "says plainly that nobody has endorsed it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/start/guidance")

      assert has_element?(view, "#guidance-lede", "nobody has reviewed or endorsed")
    end
  end

  test "copy says Bitcoin, and keeps technical names", %{conn: conn} do
    for path <- @pages do
      {:ok, view, _html} = live(conn, path)
      refute render(view) =~ "Bitcoin SV"
    end
  end
end
