defmodule BitblocksWeb.IndexNotice do
  @moduledoc """
  The site banner's one fact: how far the index reaches.

  Bitblocks is accurate as of the last-known block, so the banner names that
  block and how long ago it was mined, from the shared sync snapshot
  (`Bitblocks.SyncProgress`, an ETS read) and one lookup by height. Until the
  snapshot knows a block, there is no banner.
  """

  use Phoenix.Component

  import BitblocksWeb.Sats, only: [delimit: 1]

  require Logger

  alias Bitblocks.{Chain, SyncProgress}

  @typedoc "The block the index is complete through."
  @type t :: %{height: non_neg_integer(), time: integer()}

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts), do: Plug.Conn.assign(conn, :index_notice, current())

  @doc """
  The block the index is complete through, with its time, or nil.

  Deploy answers `/` before `bin/migrate`, so a failed lookup is logged and
  leaves the banner off rather than turning a page into a 500.
  """
  @spec current() :: t() | nil
  def current do
    with %{complete_through: height} when is_integer(height) and height >= 0 <-
           SyncProgress.snapshot().overview,
         time when is_integer(time) <- Chain.block_time(height) do
      %{height: height, time: time}
    else
      _ -> nil
    end
  rescue
    exception ->
      Logger.error("index notice unavailable: #{Exception.message(exception)}")
      nil
  end

  @doc """
  A span of time in the largest whole unit: "3 hours", "12 years".
  Under a minute reads "moments".
  """
  @spec span(integer()) :: String.t()
  def span(seconds) when seconds < 60, do: "moments"
  def span(seconds) when seconds < 3_600, do: unit(div(seconds, 60), "minute")
  def span(seconds) when seconds < 86_400, do: unit(div(seconds, 3_600), "hour")
  def span(seconds) when seconds < 2_592_000, do: unit(div(seconds, 86_400), "day")
  def span(seconds) when seconds < 31_536_000, do: unit(div(seconds, 2_592_000), "month")
  def span(seconds), do: unit(div(seconds, 31_536_000), "year")

  defp unit(1, name), do: "1 #{name}"
  defp unit(n, name), do: "#{n} #{name}s"

  attr(:notice, :any, default: nil)
  attr(:now, :integer, default: nil)

  def banner(assigns) do
    assigns = assign(assigns, :now, assigns.now || System.system_time(:second))

    ~H"""
    <div
      :if={@notice}
      id="banner"
      role="region"
      aria-label="How far the index reaches"
      class="relative flex items-center gap-x-6 bg-orange-500 bg-opacity-30 px-6 py-2.5 sm:px-3.5 sm:before:flex-1"
    >
      <p
        id="banner-text"
        class="text-sm/6 text-gray-900 dark:text-gray-100"
      >
        <strong
          class="font-semibold"
        >
          In development.
        </strong>
        Every transaction is stored through block
        <span
          class="font-mono tabular-nums"
        ><%= delimit(@notice.height) %></span>,
        mined <%= span(@now - @notice.time) %> ago.
      </p>
      <div
        class="flex flex-1 justify-end"
      >
        <button
          type="button"
          class="-m-3 p-3 focus-visible:-outline-offset-4"
          onclick="document.getElementById('banner').style.display='none'"
          aria-label="Dismiss this notice"
        >
          <span
            class="sr-only"
          >
            Dismiss
          </span>
          <svg
            viewBox="0 0 20 20"
            fill="currentColor"
            data-slot="icon"
            aria-hidden="true"
            class="size-5 text-gray-900 dark:text-gray-100"
          >
            <path
              d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 0 0-1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z"
            />
          </svg>
        </button>
      </div>
    </div>
    """
  end
end
