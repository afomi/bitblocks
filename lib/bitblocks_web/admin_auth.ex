defmodule BitblocksWeb.AdminAuth do
  @moduledoc """
  Whether the sign-in gates are enforced (`BitblocksWeb.UserAuth`).

  The gates run in every env. Enforcement is a runtime config:

      config :bitblocks, :admin_auth, enabled: true | false

  It defaults to enabled (fail-closed) when unset. Test disables it in
  config/test.exs so LiveView and controller tests can reach the operator
  surface; test/bitblocks_web/admin_gate_test.exs re-enables it.
  """

  @doc """
  Whether the gates are enforced. Defaults to `true` when the key is absent.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :bitblocks
    |> Application.get_env(:admin_auth, [])
    |> Keyword.get(:enabled, true)
  end
end
