defmodule BitblocksWeb.AdminAuth do
  @moduledoc """
  Decides whether the admin basic-auth credentials are acceptable to serve with.

  ## Why this exists

  The admin surface (`/config`, `/debug`, `/sync`, edit pages) is gated by HTTP
  basic auth whose credentials fall back to `admin`/`secret` when the
  `ADMIN_USERNAME`/`ADMIN_PASSWORD` env vars are unset. Shipping those defaults
  in production is an elevation-of-privilege hole (THREAT-MODEL.md T10): the
  admin panel would be trivially owned. This module fails closed — in
  production, default/unset credentials are refused outright.

  The decision is a pure function of (env, username, password) so it can be
  tested directly; the router calls `decision/0` which reads the live env.

  ## Enablement

  The gate itself runs in EVERY env (the router no longer bypasses it in
  dev/test at compile time). Whether auth is enforced is a *runtime* config:

      config :bitblocks, :admin_auth, enabled: true | false

  It defaults to enabled (fail-closed) when unset. Test disables it in
  config/test.exs so LiveView/controller tests can reach the operator surface
  unauthenticated; the gate is still covered by
  test/bitblocks_web/admin_gate_test.exs, which re-enables it. In dev the
  defaults are allowed but a warning is logged so the operator knows to set
  ADMIN_USERNAME/ADMIN_PASSWORD.
  """

  require Logger

  @default_user "admin"
  @default_pass "secret"

  @doc """
  Whether admin basic auth is enforced at all.

  Reads `config :bitblocks, :admin_auth, enabled: boolean` at runtime.
  Defaults to `true` (fail-closed) when the key is absent.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :bitblocks
    |> Application.get_env(:admin_auth, [])
    |> Keyword.get(:enabled, true)
  end

  @doc "Resolve the auth decision from the current environment."
  @spec decision() :: {:ok, String.t(), String.t()} | {:error, :default_credentials}
  def decision do
    user = System.get_env("ADMIN_USERNAME") || @default_user
    pass = System.get_env("ADMIN_PASSWORD") || @default_pass

    maybe_warn_dev_defaults(env(), user, pass)

    decide(env(), user, pass)
  end

  @doc """
  Pure decision: `{:ok, user, pass}` to proceed with basic auth, or
  `{:error, :default_credentials}` to refuse.

  In dev/test the convenient defaults are allowed. In any other environment,
  using the default username or password is refused.
  """
  @spec decide(atom(), String.t(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :default_credentials}
  def decide(env, user, pass)

  def decide(env, user, pass) when env in [:dev, :test], do: {:ok, user, pass}

  def decide(_env, user, pass) do
    if user == @default_user or pass == @default_pass do
      {:error, :default_credentials}
    else
      {:ok, user, pass}
    end
  end

  # In dev the convenience defaults are accepted, but noisily: the operator
  # surface is now gated in every env, so a dev operator should know exactly
  # which credentials open it and how to change them.
  defp maybe_warn_dev_defaults(:dev, user, pass) do
    if user == @default_user or pass == @default_pass do
      Logger.warning(
        "Admin auth is using the dev-default credentials (#{@default_user}/#{@default_pass}). " <>
          "Set ADMIN_USERNAME/ADMIN_PASSWORD to override."
      )
    end

    :ok
  end

  defp maybe_warn_dev_defaults(_env, _user, _pass), do: :ok

  @doc """
  The email addresses whose owners are admins, trimmed and lowercased.

  Set from `ADMIN_EMAILS` (comma-separated) in config/runtime.exs as
  `config :bitblocks, :admin_emails, [...]`. Empty means no GitHub user is an
  admin; basic auth still works.
  """
  @spec admin_emails() :: [String.t()]
  def admin_emails do
    :bitblocks
    |> Application.get_env(:admin_emails, [])
    |> List.wrap()
    |> Enum.map(&normalize_email/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  The addresses in `emails` that are on `ADMIN_EMAILS` (normalized).

  `emails` must be the person's VERIFIED GitHub addresses
  (`Bitblocks.Accounts.verified_github_emails/1`), never the profile email.
  The sign-in keeps this list in the session, so non-admins carry no address.
  """
  @spec matching_admin_emails([String.t()] | nil) :: [String.t()]
  def matching_admin_emails(emails) when is_list(emails) do
    allowed = admin_emails()

    emails
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_email/1)
    |> Enum.filter(&(&1 != "" and &1 in allowed))
    |> Enum.uniq()
  end

  def matching_admin_emails(_), do: []

  @doc """
  Whether any of these verified addresses is on `ADMIN_EMAILS`, checked
  against the list as it is now (so dropping an address revokes admin).
  """
  @spec admin_email?([String.t()] | nil) :: boolean()
  def admin_email?(emails), do: matching_admin_emails(emails) != []

  @doc "An email address as compared for admin: trimmed and lowercased."
  @spec normalize_email(term()) :: String.t()
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(_), do: ""

  @doc """
  Whether the request carries valid admin basic-auth credentials.

  Non-challenging: returns `false` for a missing or wrong header, and for
  production running on the default credentials (T10), so the caller decides
  how to respond.
  """
  @spec valid_basic_auth?(Plug.Conn.t()) :: boolean()
  def valid_basic_auth?(conn) do
    with {given_user, given_pass} <- Plug.BasicAuth.parse_basic_auth(conn),
         {:ok, user, pass} <- decision() do
      Plug.Crypto.secure_compare(given_user, user) and
        Plug.Crypto.secure_compare(given_pass, pass)
    else
      _ -> false
    end
  end

  defp env, do: Application.get_env(:bitblocks, :admin_auth_env, default_env())

  # Compile-time Mix.env() is the right default; tests override via config.
  if Mix.env() do
    defp default_env, do: unquote(Mix.env())
  end
end
