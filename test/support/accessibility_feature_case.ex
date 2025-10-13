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
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Bitblocks.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Bitblocks.Repo, {:shared, self()})
    end

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Bitblocks.Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    {:ok, session: session}
  end
end
