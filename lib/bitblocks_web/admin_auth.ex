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
  """

  @default_user "admin"
  @default_pass "secret"

  @doc "Resolve the auth decision from the current environment."
  @spec decision() :: {:ok, String.t(), String.t()} | {:error, :default_credentials}
  def decision do
    decide(
      env(),
      System.get_env("ADMIN_USERNAME") || @default_user,
      System.get_env("ADMIN_PASSWORD") || @default_pass
    )
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

  defp env, do: Application.get_env(:bitblocks, :admin_auth_env, default_env())

  # Compile-time Mix.env() is the right default; tests override via config.
  if Mix.env() do
    defp default_env, do: unquote(Mix.env())
  end
end
