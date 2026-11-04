defmodule BitblocksWeb.AuthController do
  @moduledoc """
  GitHub sign-in (Ueberauth), sign-out, and the sign-in page.

  Ueberauth runs at request time through `Ueberauth.run_request/3` and
  `Ueberauth.run_callback/3`, so the client id, secret and callback URL all
  come from runtime config (config/runtime.exs) rather than compile time.

  We request one OAuth scope, `user:email` (read-only access to the person's
  email addresses), on top of the public profile. Admins are chosen by
  verified email (`ADMIN_EMAILS`, see `BitblocksWeb.AdminAuth`), and a
  private GitHub address is only visible with that scope. ueberauth_github
  fetches `GET /user/emails` itself during the callback; we keep only the
  verified addresses that match, in the session. The access token is
  discarded after the callback.
  CSRF on the OAuth round trip is Ueberauth's signed `state` cookie; sign-out
  is a DELETE through the `:browser` pipeline's `protect_from_forgery`.
  """
  use BitblocksWeb, :controller

  require Logger

  alias Bitblocks.Accounts
  alias BitblocksWeb.AdminAuth
  alias BitblocksWeb.UserAuth

  @return_to_key "user_return_to"

  # Read-only access to the person's email addresses (GET /user/emails).
  @scope "user:email"

  plug :ensure_github_configured when action in [:request, :callback]

  @doc "The sign-in page: a GitHub link, or a note that sign-in isn't set up."
  def sign_in(conn, params) do
    return_to = UserAuth.safe_return_to(params["return_to"])

    render(conn, :sign_in,
      page_title: "Sign in",
      github_configured?: UserAuth.github_configured?(),
      github_path: UserAuth.github_path(return_to)
    )
  end

  @doc "Start the GitHub OAuth round trip, remembering where to come back to."
  def request(conn, params) do
    canonical = github_options()[:canonical_host]

    if canonical && conn.host != canonical do
      # Session and state cookies are per host: run the whole round trip on
      # the host the GitHub app's callback URL names.
      redirect(conn, external: "https://#{canonical}#{UserAuth.github_path(params["return_to"])}")
    else
      conn
      |> put_session(@return_to_key, UserAuth.safe_return_to(params["return_to"]))
      # A caller-supplied ?scope= would widen what GitHub grants; we ask only
      # for @scope.
      |> Map.update!(:params, &Map.delete(&1, "scope"))
      |> Ueberauth.run_request("github", provider())
    end
  end

  @doc """
  GitHub's redirect back: create or refresh the user and sign them in.

  When the conn already carries an Ueberauth result (tests assign one), the
  GitHub exchange is skipped.
  """
  def callback(conn, _params) do
    conn =
      if Map.has_key?(conn.assigns, :ueberauth_auth) or
           Map.has_key?(conn.assigns, :ueberauth_failure),
         do: conn,
         else: Ueberauth.run_callback(conn, "github", provider())

    if conn.halted, do: conn, else: handle_callback(conn)
  end

  defp handle_callback(%{assigns: %{ueberauth_failure: failure}} = conn) do
    Logger.info("GitHub sign-in failed: #{inspect(failure && failure.errors)}")

    conn
    |> put_flash(:error, "GitHub sign-in didn't complete. Please try again.")
    |> redirect(to: ~p"/sign-in")
  end

  defp handle_callback(%{assigns: %{ueberauth_auth: auth}} = conn) do
    case Accounts.upsert_github_user(auth) do
      {:ok, user} ->
        return_to = get_session(conn, @return_to_key)

        conn
        # A fresh session id on sign-in, so a planted session can't be reused.
        |> configure_session(renew: true)
        |> delete_session(@return_to_key)
        |> put_session("user_id", user.id)
        # Rewritten on every sign-in, so an address removed or unverified on
        # GitHub stops making this person an admin.
        |> put_session(
          "admin_emails",
          auth |> Accounts.verified_github_emails() |> AdminAuth.matching_admin_emails()
        )
        |> put_flash(:info, "Signed in as #{user.login}.")
        |> redirect(to: UserAuth.safe_return_to(return_to) || ~p"/")

      {:error, changeset} ->
        Logger.warning("GitHub sign-in could not save the user: #{inspect(changeset.errors)}")

        conn
        |> put_flash(:error, "GitHub sign-in didn't complete. Please try again.")
        |> redirect(to: ~p"/sign-in")
    end
  end

  defp handle_callback(conn) do
    conn
    |> put_flash(:error, "GitHub sign-in didn't complete. Please try again.")
    |> redirect(to: ~p"/sign-in")
  end

  @doc "Sign out: clear the whole session."
  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/")
  end

  defp ensure_github_configured(conn, _opts) do
    if UserAuth.github_configured?() do
      conn
    else
      conn
      |> put_flash(:error, "GitHub sign-in isn't configured on this server yet.")
      |> redirect(to: ~p"/sign-in")
      |> halt()
    end
  end

  defp provider do
    # allow_private_emails only invents a noreply address for info.email,
    # which we never read; verified addresses come from GET /user/emails.
    options =
      [default_scope: @scope, allow_private_emails: false]
      |> maybe_put(:callback_url, github_options()[:callback_url])

    {Ueberauth.Strategy.Github, options}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp github_options, do: Application.get_env(:bitblocks, :github_oauth, [])
end
