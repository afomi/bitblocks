defmodule BitblocksWeb.StartComponents do
  @moduledoc """
  Markup shared by the `/start` pages: the frame and its tabs, the step rail,
  status labels, code panels and links out.

  Colours follow DESIGN.md: orange is the chain (the rail and the coverage bar),
  blue is a link, green says it works today, amber says it's coming or a draft.
  """
  use Phoenix.Component

  @tabs [
    {"path", "/start", "The path"},
    {"api", "/start/api", "API"},
    {"guidance", "/start/guidance", "Guidance"}
  ]

  @doc "The page frame, with a tab for each `/start` page."
  attr :current, :string, required: true
  slot :inner_block, required: true

  def start_page(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div class="mx-auto max-w-3xl px-4 py-10">
      <nav
        id="start-tabs"
        aria-label="Getting started"
        class="mb-8 flex gap-6 border-b border-gray-200 text-sm dark:border-gray-700"
      >
        <a
          :for={{id, href, label} <- @tabs}
          href={href}
          aria-current={if id == @current, do: "page"}
          class={[
            "-mb-px border-b-2 pb-2",
            if(id == @current,
              do: "border-orange-500 font-semibold text-gray-900 dark:text-white",
              else:
                "border-transparent text-blue-700 hover:text-blue-900 dark:text-blue-400 dark:hover:text-blue-300"
            )
          ]}
        >
          {label}
        </a>
      </nav>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A short status. `today` works now with no account, and `signed_in` works now
  after GitHub sign-in. `coming` isn't built. `position` is a view we hold, and
  `draft` a view still to be confirmed.
  """
  attr :kind, :string, required: true

  def status(%{kind: kind} = assigns) when kind in ~w(today signed_in position) do
    ~H"""
    <span class="text-xs font-semibold text-green-700 dark:text-green-400">
      {status_label(@kind)}
    </span>
    """
  end

  def status(%{kind: kind} = assigns) when kind in ~w(coming draft) do
    ~H"""
    <span class="rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-semibold text-amber-900 dark:bg-amber-900/40 dark:text-amber-200">
      {status_label(@kind)}
    </span>
    """
  end

  defp status_label("today"), do: "Works today, no account needed"
  defp status_label("signed_in"), do: "Works today, signed in"
  defp status_label("coming"), do: "Coming"
  defp status_label("position"), do: "Our position"
  defp status_label("draft"), do: "Draft"

  @doc "One step on the rail: a numbered block, joined to the next by the chain."
  attr :id, :string, required: true
  attr :n, :integer, required: true
  attr :title, :string, required: true
  attr :status, :string, default: nil
  attr :last, :boolean, default: false
  slot :inner_block, required: true

  def step(assigns) do
    ~H"""
    <li
      id={@id}
      class="relative pb-10 pl-12 last:pb-0"
    >
      <span
        :if={!@last}
        aria-hidden="true"
        class="absolute bottom-0 left-4 top-8 w-px bg-orange-500 dark:bg-orange-400"
      ></span>
      <span
        aria-hidden="true"
        class="absolute left-0 top-0 flex h-8 w-8 items-center justify-center rounded border-2 border-orange-500 bg-white font-mono text-sm font-semibold tabular-nums text-gray-900 dark:border-orange-400 dark:bg-gray-900 dark:text-white"
      >
        {@n}
      </span>
      <div class="mb-2 flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 class="text-lg font-semibold text-gray-900 dark:text-white">
          {@title}
        </h3>
        <.status
          :if={@status}
          kind={@status}
        />
      </div>
      <div class="space-y-3 text-sm leading-relaxed text-gray-700 dark:text-gray-300">
        {render_slot(@inner_block)}
      </div>
    </li>
    """
  end

  @doc """
  Code or a response, keyboard-scrollable when it runs wide. Takes the text as
  an attribute, so the template's indentation never ends up in the example.
  """
  attr :label, :string, required: true
  attr :code, :string, required: true

  def code_panel(assigns) do
    ~H"""
    <figure class="rounded-lg border border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800">
      <figcaption class="border-b border-gray-200 px-3 py-1.5 text-xs text-gray-600 dark:border-gray-700 dark:text-gray-400">
        {@label}
      </figcaption>
      <pre
        tabindex="0"
        aria-label={@label}
        class="overflow-x-auto p-3 font-mono text-xs leading-relaxed text-gray-800 dark:text-gray-200"
      ><code>{@code}</code></pre>
    </figure>
    """
  end

  @doc "A link inside a sentence: underlined, per DESIGN.md."
  attr :href, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def text_link(assigns) do
    ~H"""
    <a
      id={@id}
      href={@href}
      class="underline text-blue-700 hover:text-blue-900 dark:text-blue-400 dark:hover:text-blue-300"
    >{render_slot(@inner_block)}</a>
    """
  end

  @doc "A link that leaves Bitblocks, on its own line, with what it is."
  attr :href, :string, required: true
  attr :name, :string, required: true
  slot :inner_block, required: true

  def out_link(assigns) do
    ~H"""
    <li class="py-3">
      <a
        href={@href}
        rel="noopener"
        class="font-medium text-blue-700 hover:text-blue-900 dark:text-blue-400 dark:hover:text-blue-300"
      >
        {@name}
      </a>
      <p class="mt-0.5 text-sm text-gray-600 dark:text-gray-400">
        {render_slot(@inner_block)}
      </p>
    </li>
    """
  end

  @doc "The heading that opens a strand."
  attr :id, :string, required: true
  slot :inner_block, required: true

  def strand_heading(assigns) do
    ~H"""
    <h2
      id={@id}
      class="mb-2 text-xl font-semibold text-gray-900 dark:text-white"
    >
      {render_slot(@inner_block)}
    </h2>
    """
  end
end
