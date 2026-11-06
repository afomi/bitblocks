defmodule BitblocksWeb.StartLive.Guidance do
  @moduledoc """
  `/start/guidance`: Bitblocks' own views on identity, wallets, standards,
  experiences, applications, resources and what we find interesting. Each says
  why and carries a date, and every one is a draft until Ryan confirms it
  (`docs/DEMOS_CAMPAIGN.md`).

  Admin only until published, like `/start`.
  """
  use BitblocksWeb, :live_view

  import BitblocksWeb.StartComponents

  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(
       socket,
       Seo.public_page(
         page_title: "How we think about building on Bitcoin",
         meta_description:
           "Bitblocks' views on standards, identity, wallets and building on Bitcoin.",
         canonical_path: "/start/guidance",
         meta_robots: "noindex, nofollow"
       )
     )}
  end

  @doc "One view: its heading, status, date and reasons."
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :claim, :string, required: true
  attr :status, :string, required: true
  attr :date, :string, required: true
  slot :inner_block, required: true

  def view(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={"#{@id}-heading"}
      class="mb-12 scroll-mt-6"
    >
      <h2
        id={"#{@id}-heading"}
        class="text-sm font-semibold text-gray-600 dark:text-gray-400"
      >
        {@title}
      </h2>
      <p class="mt-1 text-xl font-semibold text-gray-900 dark:text-white">
        {@claim}
      </p>
      <p class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1">
        <.status kind={@status} />
        <span class="font-mono text-xs tabular-nums text-gray-600 dark:text-gray-400">
          {@date}
        </span>
      </p>
      <div class="mt-3 space-y-3 text-sm leading-relaxed text-gray-700 dark:text-gray-300">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
