defmodule BitblocksWeb.ReorgNotice do
  @moduledoc """
  Loads the current reorg announcement onto every HTML page.

  The plug covers controller renders.
  `on_mount` covers LiveViews after they connect.
  """

  use Phoenix.Component

  require Logger

  alias Bitblocks.Reorgs
  alias Bitblocks.Reorgs.Reorg

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    Plug.Conn.assign(conn, :reorg_notice, current())
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, :reorg_notice, current())}
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

  def banner(assigns) do
    ~H"""
    <div
      :if={@notice}
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
          Read the reorg timeline.
        </a>
      </p>
    </div>
    """
  end
end
