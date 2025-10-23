defmodule BitblocksWeb.AccessibilityFeatureCase do
  @moduledoc """
  Feature test case for accessibility testing with Wallaby and axe-core.

  Uses a11y_audit to run axe-core accessibility checks in browser tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      import Wallaby.Query, only: [css: 1, css: 2]
      import BitblocksWeb.AccessibilityFeatureCase
      import A11yAudit.Wallaby
    end
  end

  setup tags do
    # Set up database sandbox using the same pattern as DataCase
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Bitblocks.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Set up RPC stubs so tests don't need a real Bitcoin node
    BitblocksWeb.RpcStub.setup()
    on_exit(fn -> BitblocksWeb.RpcStub.stop() end)

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Bitblocks.Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    {:ok, session: session}
  end
end
