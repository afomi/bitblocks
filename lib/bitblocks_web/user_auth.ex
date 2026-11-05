defmodule BitblocksWeb.UserAuth do
  @moduledoc """
  Who is signed in, and what they may open.

  ## Access model

    * **Public** - the explorer front: home, `/blocks`, the beta features, the
      API. No sign-in.
    * **Signed in** (`:require_user`) - block and transaction detail,
      `/status`, `/syncing`. Any GitHub user.
    * **Admin** (`:require_admin`) - the operator surface. A GitHub user whose
      row has `admin: true` (set with `Release.set_admin/2`, keyed by their
      GitHub numeric id).

  ## Session keys

  The GitHub callback writes only `"user_id"` to the signed session cookie.
  Admin is read from the user's row on each request, so granting or revoking
  it takes effect on the next page load, with no new sign-in. The admin data
  routes (chain-scrubber tiles, flow, annotations) do one primary-key lookup
  for that, and only while the gate is on.

  ## Enforcement

  Both gates follow `BitblocksWeb.AdminAuth.enabled?/0`. Production and dev
  enforce; config/test.exs turns the gate off so the suite can reach every
  page, and test/bitblocks_web/user_auth_test.exs turns it back on.
  """

  use BitblocksWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  require Logger

  alias Bitblocks.Accounts
  alias BitblocksWeb.AdminAuth

  ## Configuration

  @doc "Whether the gates are enforced."
  @spec enforced?() :: boolean()
  def enforced?, do: AdminAuth.enabled?()

  @doc "Whether GitHub sign-in has a client id and secret to work with."
  @spec github_configured?() :: boolean()
  def github_configured? do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, [])
    present?(config[:client_id]) and present?(config[:client_secret])
  end

  defp present?(value), do: is_binary(value) and value != ""

  ## Paths

  @doc """
  A return path we are willing to redirect to: a local path only.

  Anything with a scheme or host, or that a browser would read as one
  (`//host`, `/\\host`), is refused with nil.
  """
  @spec safe_return_to(term()) :: String.t() | nil
  def safe_return_to("/" <> rest = path) do
    cond do
      String.starts_with?(rest, ["/", "\\"]) -> nil
      String.contains?(path, ["\r", "\n"]) -> nil
      match?(%URI{scheme: nil, host: nil}, URI.parse(path)) -> path
      true -> nil
    end
  end

  def safe_return_to(_), do: nil

  @doc "The sign-in page, carrying the path to return to afterwards."
  @spec sign_in_path(String.t() | nil) :: String.t()
  def sign_in_path(return_to) do
    case safe_return_to(return_to) do
      nil -> ~p"/sign-in"
      path -> ~p"/sign-in?#{[return_to: path]}"
    end
  end

  @doc "The GitHub request phase, carrying the path to return to afterwards."
  @spec github_path(String.t() | nil) :: String.t()
  def github_path(return_to) do
    case safe_return_to(return_to) do
      nil -> "/auth/github"
      path -> "/auth/github?" <> URI.encode_query(return_to: path)
    end
  end

  ## Plugs

  @doc """
  Plug for the `:browser` pipeline: assigns `:current_user`, `:admin?` and
  `:current_path`.

  `:admin?` is true for a signed-in admin, and whenever the gate is off.
  """
  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, "user_id")
    user = Accounts.get_user(user_id)

    # A session pointing at a user that no longer exists is dropped.
    conn =
      if user_id && is_nil(user),
        do: delete_session(conn, "user_id"),
        else: conn

    conn
    |> assign(:current_user, user)
    |> assign(:admin?, admin_request?(user))
    |> assign(:current_path, current_path(conn))
  end

  @doc "Plug: signed-in users and admins pass; everyone else is sent to sign in."
  def require_user(conn, _opts) do
    if (not enforced?() or conn.assigns[:current_user]) || conn.assigns[:admin?] do
      conn
    else
      conn
      |> redirect(to: sign_in_path(conn.assigns[:current_path] || current_path(conn)))
      |> halt()
    end
  end

  @doc "Plug for the `:admin` pipeline (runs after `:browser`)."
  def require_admin(conn, _opts) do
    cond do
      not enforced?() -> conn
      conn.assigns[:admin?] -> conn
      true -> refuse_admin(conn, signed_in?: not is_nil(conn.assigns[:current_user]), html?: true)
    end
  end

  @doc """
  Plug for `:admin_data` (chain-scrubber tiles): no `:browser`, no database.

  Admits an admin from the signed session cookie.
  """
  def require_admin_data(conn, _opts) do
    conn = fetch_session(conn)

    cond do
      not enforced?() ->
        conn

      admin_request?(Accounts.get_user(get_session(conn, "user_id"))) ->
        conn

      true ->
        refuse_admin(conn, signed_in?: not is_nil(get_session(conn, "user_id")), html?: false)
    end
  end

  defp admin_request?(user), do: not enforced?() or admin_user?(user)

  defp admin_user?(%Accounts.User{admin: true}), do: true
  defp admin_user?(_), do: false

  # Why the admin gate said no, and the most useful answer for each case:
  #
  #   * signed in, not an admin: 403;
  #   * anonymous on a page: the GitHub sign-in, or a 503 if it isn't configured;
  #   * anonymous on admin data: 401.
  defp refuse_admin(conn, opts) do
    cond do
      opts[:signed_in?] ->
        forbidden(conn, opts[:html?])

      not opts[:html?] ->
        conn |> send_resp(401, "Sign in as an admin") |> halt()

      github_configured?() ->
        conn |> redirect(to: sign_in_path(current_path(conn))) |> halt()

      true ->
        Logger.error("Admin auth refused: GitHub sign-in isn't configured")
        conn |> send_resp(503, "Admin interface not configured") |> halt()
    end
  end

  defp forbidden(conn, true) do
    conn
    |> put_status(403)
    |> put_view(html: BitblocksWeb.AuthHTML)
    |> render(:forbidden, page_title: "Admins only")
    |> halt()
  end

  defp forbidden(conn, _html?), do: conn |> send_resp(403, "Admins only") |> halt()

  ## LiveView hooks

  @doc """
  `on_mount` hooks:

    * `:mount_current_user` - assigns `:current_user` and `:admin?`.
    * `:require_user` - also requires a signed-in user or an admin.
    * `:require_admin` - also requires an admin.

  The router plugs answer the HTTP request first; these hooks hold the same
  line for the websocket, which no plug sees.
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:require_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if (not enforced?() or socket.assigns.current_user) || socket.assigns.admin? do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.admin? do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      Accounts.get_user(session["user_id"])
    end)
    |> then(fn socket ->
      user = socket.assigns.current_user

      Phoenix.Component.assign(
        socket,
        :admin?,
        admin_request?(user)
      )
    end)
  end
end
