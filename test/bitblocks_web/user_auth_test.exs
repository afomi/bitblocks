defmodule BitblocksWeb.UserAuthTest do
  @moduledoc """
  Who may open what, with the gate enforced as it is in production.

  config/test.exs turns the gate off so the rest of the suite can reach every
  page; these tests turn it back on for their own duration. async: false
  because the flag and the admin allowlist are global application env.
  """
  use BitblocksWeb.ConnCase, async: false
  use Oban.Testing, repo: Bitblocks.Repo

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  alias Bitblocks.Accounts
  alias Bitblocks.Chain

  setup do
    previous_gate = Application.get_env(:bitblocks, :admin_auth)
    previous_logins = Application.get_env(:bitblocks, :admin_github_logins)

    Application.put_env(:bitblocks, :admin_auth, enabled: true)
    Application.put_env(:bitblocks, :admin_github_logins, ["Afomi"])

    on_exit(fn ->
      restore(:admin_auth, previous_gate)
      restore(:admin_github_logins, previous_logins)
    end)

    block = block_fixture(tx: Enum.map(1..120, &txid/1), num_tx: 120)
    %{block: block}
  end

  defp restore(key, nil), do: Application.delete_env(:bitblocks, key)
  defp restore(key, value), do: Application.put_env(:bitblocks, key, value)

  defp txid(n), do: n |> Integer.to_string() |> String.pad_leading(64, "0")

  defp github_user(login, id) do
    {:ok, user} =
      Accounts.upsert_github_user(%Ueberauth.Auth{
        provider: :github,
        uid: id,
        info: %Ueberauth.Auth.Info{nickname: login, name: login, image: nil}
      })

    user
  end

  defp sign_in(conn, user) do
    init_test_session(conn, %{"user_id" => user.id, "user_login" => user.login})
  end

  defp basic_auth(conn) do
    {:ok, user, pass} = BitblocksWeb.AdminAuth.decision()
    put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{pass}"))
  end

  describe "an anonymous visitor" do
    test "is sent to sign in from block detail, with the way back", %{conn: conn, block: block} do
      conn = get(conn, "/blocks/#{block.height}")

      assert redirected_to(conn) == "/sign-in?return_to=%2Fblocks%2F#{block.height}"
    end

    test "is sent to sign in from transaction pages", %{conn: conn} do
      assert redirected_to(get(conn, "/transactions/#{txid(1)}")) =~ "/sign-in?return_to="
      assert redirected_to(get(conn, "/transactions")) =~ "/sign-in?return_to="
    end

    test "still sees the public pages", %{conn: conn} do
      for path <- ["/", "/blocks", "/status", "/tokens", "/about"] do
        assert get(conn, path).status == 200, "#{path} should stay public"
      end
    end

    test "sees a sign-in page that explains when GitHub isn't configured", %{conn: conn} do
      html = html_response(get(conn, "/sign-in?return_to=/blocks/1"), 200)

      assert html =~ "Sign in"
      assert html =~ "isn't configured"
      refute html =~ ~s(href="/auth/github)
    end

    test "sees a GitHub link carrying the return path when GitHub is configured", %{conn: conn} do
      with_github_configured(fn ->
        html = html_response(get(conn, "/sign-in?return_to=/blocks/1"), 200)
        assert html =~ ~s(href="/auth/github?return_to=%2Fblocks%2F1")
      end)
    end

    test "sees a GitHub sign-in link in the nav only when it's configured", %{conn: conn} do
      refute html_response(get(conn, "/about"), 200) =~ ~s(id="nav-sign-in")

      with_github_configured(fn ->
        html = html_response(get(conn, "/about"), 200)
        assert html =~ ~s(id="nav-sign-in")
        assert html =~ ~s(id="nav-sign-in-mobile")
        assert html =~ ~s(href="/auth/github?return_to=%2Fabout")
      end)
    end

    test "gets the basic auth challenge on the operator surface", %{conn: conn} do
      conn = get(conn, "/sync")
      assert conn.status == 401
      assert [_ | _] = get_resp_header(conn, "www-authenticate")
    end
  end

  describe "a signed-in GitHub user who isn't an admin" do
    setup %{conn: conn} do
      %{conn: sign_in(conn, github_user("reader", 1001))}
    end

    test "can read block detail, one page of txids at a time", %{conn: conn, block: block} do
      {:ok, view, html} = live(conn, "/blocks/#{block.height}")

      assert html =~ ~s(href="/transactions/#{txid(1)}")
      assert html =~ ~s(href="/transactions/#{txid(50)}")
      refute html =~ txid(51)

      %{socket: socket} = :sys.get_state(view.pid)
      assert socket.assigns.block.tx == nil, "the full txid array must not sit in the socket"
      assert length(socket.assigns.txids) == 50
      assert socket.assigns.tx_total == 120

      html = render_click(view, "tx_page", %{"page" => "3"})
      assert html =~ txid(101)
      assert html =~ txid(120)
      refute html =~ ~s(href="/transactions/#{txid(1)}")
    end

    test "follows a txid link from the block to the transaction page", %{conn: conn} do
      block = block_fixture()

      transaction_fixture(
        txid: txid(1),
        block_hash: block.hash,
        block_height: block.height
      )

      {:ok, _view, html} = live(conn, "/transactions/#{txid(1)}")
      assert html =~ txid(1)
    end

    test "does not see or trigger the transaction download", %{conn: conn, block: block} do
      {:ok, view, html} = live(conn, "/blocks/#{block.height}")

      refute html =~ ~s(phx-click="download_transactions")

      render_hook(view, "download_transactions", %{})

      assert Chain.get_block(block.height).sync_state == block.sync_state
      refute_enqueued(worker: Bitblocks.Workers.FetchTransactionsWorker)
    end

    test "is refused on /sync and /chain-scrubber", %{conn: conn} do
      assert get(conn, "/sync").status == 403
      assert get(conn, "/chain-scrubber").status == 403
      assert get(conn, "/chain-scrubber/tiles/manifest").status == 403
    end

    test "sees their login and sign-out in the nav, desktop and mobile", %{conn: conn} do
      html = html_response(get(conn, "/"), 200)

      assert html =~ ~s(id="nav-user")
      assert html =~ "reader"
      assert html =~ ~s(id="nav-sign-out")
      assert html =~ ~s(id="nav-sign-out-mobile")
      assert html =~ ~s(data-method="delete")
      refute html =~ ~s(id="nav-sign-in")
    end

    test "can sign out with a DELETE", %{conn: conn, block: block} do
      conn = delete(conn, "/auth/logout")
      assert redirected_to(conn) == "/"

      conn = get(recycle(conn), "/blocks/#{block.height}")
      assert redirected_to(conn) =~ "/sign-in"
    end
  end

  describe "an allowlisted GitHub admin" do
    setup %{conn: conn} do
      # Allowlist holds "Afomi": logins match case-insensitively.
      %{conn: sign_in(conn, github_user("afomi", 2002))}
    end

    test "opens the operator surface", %{conn: conn} do
      assert get(conn, "/sync").status == 200
      assert get(conn, "/chain-scrubber").status == 200
      refute get(conn, "/chain-scrubber/tiles/manifest").status in [401, 403]
    end

    test "sees and triggers the transaction download", %{conn: conn, block: block} do
      {:ok, view, html} = live(conn, "/blocks/#{block.height}")
      assert html =~ ~s(phx-click="download_transactions")

      render_click(view, "download_transactions", %{})

      assert Chain.get_block(block.height).sync_state == "txs_queued"
      assert_enqueued(worker: Bitblocks.Workers.FetchTransactionsWorker)
    end
  end

  describe "basic auth" do
    test "still admits the admin to the operator surface", %{conn: conn} do
      assert conn |> basic_auth() |> get("/sync") |> Map.get(:status) == 200

      assert conn |> basic_auth() |> get("/chain-scrubber/tiles/manifest") |> Map.get(:status) !=
               401
    end

    test "admits the admin to detail pages, with the download button", %{conn: conn, block: block} do
      {:ok, _view, html} = live(basic_auth(conn), "/blocks/#{block.height}")
      assert html =~ ~s(phx-click="download_transactions")
    end

    test "with wrong credentials is refused", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic " <> Base.encode64("nope:wrong"))
        |> get("/sync")

      assert conn.status == 401
    end
  end

  describe "block detail" do
    test "a missing block is a 404", %{conn: conn} do
      conn = sign_in(conn, github_user("reader", 1001))

      assert_error_sent 404, fn -> get(conn, "/blocks/987654321") end
    end
  end

  describe "the GitHub callback" do
    test "creates the user, signs them in and returns them where they were", %{conn: conn} do
      auth = %Ueberauth.Auth{
        provider: :github,
        uid: 3003,
        info: %Ueberauth.Auth.Info{nickname: "newcomer", name: "New Comer", image: nil}
      }

      conn =
        conn
        |> bypass_through(BitblocksWeb.Router, [:browser])
        |> get("/auth/github/callback")
        |> put_session("user_return_to", "/blocks/7")
        |> assign(:ueberauth_auth, auth)
        |> BitblocksWeb.AuthController.callback(%{})

      assert redirected_to(conn) == "/blocks/7"
      user = Accounts.get_user_by_github_id(3003)
      assert user.login == "newcomer"
      assert get_session(conn, "user_id") == user.id
      assert get_session(conn, "user_login") == "newcomer"
    end

    test "a failed callback signs no one in", %{conn: conn} do
      conn =
        conn
        |> bypass_through(BitblocksWeb.Router, [:browser])
        |> get("/auth/github/callback")
        |> assign(:ueberauth_failure, %Ueberauth.Failure{})
        |> BitblocksWeb.AuthController.callback(%{})

      assert redirected_to(conn) == "/sign-in"
      assert get_session(conn, "user_id") == nil
    end

    test "the request phase refuses cleanly when GitHub isn't configured", %{conn: conn} do
      conn = get(conn, "/auth/github")
      assert redirected_to(conn) == "/sign-in"
    end

    test "an off-site return path is ignored", %{conn: conn} do
      assert BitblocksWeb.UserAuth.safe_return_to("//evil.example/x") == nil
      assert BitblocksWeb.UserAuth.safe_return_to("https://evil.example") == nil
      assert BitblocksWeb.UserAuth.safe_return_to("/\\evil.example") == nil
      assert BitblocksWeb.UserAuth.safe_return_to("/blocks/1?x=2") == "/blocks/1?x=2"
      assert conn
    end
  end

  defp with_github_configured(fun) do
    previous = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
      client_id: "id",
      client_secret: "secret"
    )

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, previous),
        else: Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
    end
  end
end
