defmodule BitblocksWeb.ReorgNotice do
  @moduledoc """
  Loads the current reorg announcement onto an HTML page.

  The plug runs on the HTTP request, and the root layout renders that
  assign. A LiveView does not draw the banner again when its socket
  connects, so connecting does not query.

  A reorganization is a tip event, and the banner is for admins. The plug
  asks only when this request is an admin and the index is at the chain
  tip (`Bitblocks.SyncProgress.at_chain_tip?/0`). Until then the assign is
  nil and the database is not asked.
  """

  use Phoenix.Component

  require Logger

  alias Bitblocks.Reorgs
  alias Bitblocks.Reorgs.Reorg
  alias Bitblocks.SyncProgress

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    Plug.Conn.assign(conn, :reorg_notice, notice(conn))
  end

  # The banner renders only for an admin, and only a tip the index has
  # caught can reorganize. Everyone else, and every page while we are
  # still catching up, skips the query.
  defp notice(conn) do
    if conn.assigns[:admin?] == true and SyncProgress.at_chain_tip?() do
      current()
    end
  end

  @doc """
  The announcement to show, or nil.

  Deploy answers `/` before `bin/migrate`.
  A missing `reorgs` table must not turn that check into a 500.
  """
  @spec current((-> Reorg.t() | nil)) :: Reorg.t() | nil
  def current(fetch \\ &Reorgs.active_notice/0) do
    fetch.()
  rescue
    exception ->
      Logger.error("reorg notice unavailable: #{Exception.message(exception)}")
      nil
  end

  attr(:notice, :any, default: nil)
  attr(:admin, :boolean, default: false)

  @doc """
  The banner, for admins only: a reorg here is our index disagreeing with
  the node we follow, which is operator news, not a fact about the network.
  """
  def banner(assigns) do
    ~H"""
    <div
      :if={@notice && @admin}
      id="reorg-notice"
      role="status"
      class={[
        "px-6 py-3 text-sm text-white",
        @notice.outcome == "needs_attention" && "bg-red-900",
        @notice.outcome == "resolved" && "bg-amber-900"
      ]}
    >
      <p
        class="font-semibold"
      >
        <%= if @notice.outcome == "needs_attention" do %>
          A chain reorganization needs a person.
        <% else %>
          The chain tip moved.
        <% end %>
      </p>
      <p
        class="mt-1"
      >
        <%= @notice.summary %>
      </p>
      <p
        class="mt-2"
      >
        <a
          href="/reorgs"
          class="underline font-semibold"
        >
          What a reorganization is.
        </a>
      </p>
    </div>
    """
  end
end
