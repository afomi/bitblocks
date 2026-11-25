defmodule BitblocksWeb.Freshness do
  @moduledoc """
  One plain line saying how current a page's data is (DESIGN.md, "Say how
  current it is").

      Current to block 422,382 · 554,553 blocks behind the chain
      Current to block 975,001 · the chain tip
      Files indexed through block 600,000 · 375,001 blocks behind the chain

  It always names the block. `label` keeps each page's meaning: what the
  number covers ("Current to", "Files indexed through", "Owners traced
  through"). `through` is that block and `tip` the highest block in our
  headers; both come from data the page already holds, usually the shared
  sync snapshot (`snapshot/0`, an ETS read), so the line costs no query.

  With no `tip` the line says the tip isn't known rather than guess, and
  with no `through` it says how far it reaches isn't known yet.
  """

  use Phoenix.Component

  import BitblocksWeb.Sats, only: [delimit: 1]

  alias BitblocksWeb.IndexNotice

  @doc """
  The index's reach and our headers' tip, from the shared sync snapshot
  (`Bitblocks.SyncProgress`, ETS, no query): `%{through: _, tip: _}`, either
  nil while the snapshot doesn't know.
  """
  @spec snapshot() :: %{through: integer() | nil, tip: integer() | nil}
  def snapshot do
    overview = Bitblocks.SyncProgress.snapshot().overview
    %{through: height(overview[:complete_through]), tip: height(overview[:our_tip])}
  end

  defp height(n) when is_integer(n) and n >= 0, do: n
  defp height(_), do: nil

  @doc """
  Where the line stands: `{:at_tip, through}`, `{:behind, through, blocks}`,
  `{:no_tip, through}` or `:unknown`.
  """
  @spec state(integer() | nil, integer() | nil) ::
          {:at_tip, non_neg_integer()}
          | {:behind, non_neg_integer(), pos_integer()}
          | {:no_tip, non_neg_integer()}
          | :unknown
  def state(through, tip) when is_integer(through) and through >= 0 and is_integer(tip) do
    if through >= tip, do: {:at_tip, through}, else: {:behind, through, tip - through}
  end

  def state(through, _tip) when is_integer(through) and through >= 0, do: {:no_tip, through}
  def state(_through, _tip), do: :unknown

  @doc """
  The line as plain text, as the component renders it (separators as " · ").
  """
  @spec text(String.t(), integer() | nil, integer() | nil) :: String.t()
  def text(label \\ "Current to", through, tip) do
    case state(through, tip) do
      :unknown -> "#{label}: not known yet"
      {:no_tip, n} -> "#{label} block #{delimit(n)} · chain tip not known"
      {:at_tip, n} -> "#{label} block #{delimit(n)} · the chain tip"
      {:behind, n, gap} -> "#{label} block #{delimit(n)} · #{behind(gap)}"
    end
  end

  @doc false
  def behind(1), do: "1 block behind the chain"
  def behind(gap), do: "#{delimit(gap)} blocks behind the chain"

  attr :id, :string, default: nil
  attr :label, :string, default: "Current to", doc: "what the block number covers"
  attr :through, :integer, default: nil, doc: "the block the data is current to"
  attr :tip, :integer, default: nil, doc: "the highest block in our headers"
  attr :time, :integer, default: nil, doc: "block `through`'s time (unix seconds), optional"
  attr :now, :integer, default: nil, doc: "for tests; defaults to the clock"
  attr :link, :boolean, default: false, doc: "link the block number to its page"
  attr :class, :string, default: "text-sm text-gray-600 dark:text-gray-400"
  slot :inner_block, doc: "words before the line, such as a page's own label"

  @doc "The freshness line. See the moduledoc."
  def freshness(assigns) do
    assigns =
      assigns
      |> assign(:state, state(assigns.through, assigns.tip))
      |> assign(:now, assigns.now || System.system_time(:second))

    ~H"""
    <p
      id={@id}
      role="note"
      aria-label="How current this is"
      data-freshness={freshness_kind(@state)}
      class={["break-words", @class]}
    >
      {render_slot(@inner_block)}
      <%= case @state do %>
        <% :unknown -> %>
          {@label}: not known yet
        <% state -> %>
          {@label} block
          <.block_number
            height={elem(state, 1)}
            link={@link}
          /><.mined
            :if={is_integer(@time)}
            time={@time}
            now={@now}
          />
          ·
          <span class="whitespace-nowrap">{status(state)}</span>
      <% end %>
    </p>
    """
  end

  attr :height, :integer, required: true
  attr :link, :boolean, default: false

  defp block_number(%{link: true} = assigns) do
    ~H"""
    <a
      href={"/blocks/#{@height}"}
      class="font-mono tabular-nums underline text-blue-700 hover:text-blue-900 dark:text-blue-400 dark:hover:text-blue-300"
    >{delimit(@height)}</a>
    """
  end

  defp block_number(assigns) do
    ~H"""
    <span class="font-mono tabular-nums">{delimit(@height)}</span>
    """
  end

  attr :time, :integer, required: true
  attr :now, :integer, required: true

  defp mined(assigns) do
    ~H"""
    , mined <time datetime={iso(@time)}>{IndexNotice.span(@now - @time)} ago</time>
    """
  end

  defp iso(time), do: time |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp status({:no_tip, _}), do: "chain tip not known"
  defp status({:at_tip, _}), do: "the chain tip"
  defp status({:behind, _, gap}), do: behind(gap)

  defp freshness_kind(:unknown), do: "unknown"
  defp freshness_kind(state), do: state |> elem(0) |> Atom.to_string()
end
