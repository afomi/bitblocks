defmodule BitblocksWeb.PlanComponents do
  @moduledoc """
  Monthly plans on `/pricing` (https://github.com/afomi/bitblocks/issues/112,
  `Bitblocks.Billing`): `#plans`, the plans to choose from, and `#plan`,
  "Your plan" for a subscriber. Both render nothing while plans are dormant,
  so the page reads as it did.
  """
  use Phoenix.Component

  alias Bitblocks.Billing
  alias Bitblocks.Downloads
  alias Bitblocks.Usage

  attr :plans, :list, required: true
  attr :for_sale, :boolean, required: true
  attr :current_user, :any, default: nil
  attr :subscribed, :boolean, default: false
  attr :error, :string, default: nil

  @doc "The monthly plans, each with its price, rate limit and allowance, and \"Choose\"."
  def monthly_plans(assigns) do
    ~H"""
    <section
      :if={@for_sale and @plans != []}
      id="plans"
      aria-labelledby="plans-heading"
      class="border-t border-neutral-800 py-8 scroll-mt-6"
    >
      <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-2">
        Monthly plans
      </p>
      <h2
        id="plans-heading"
        class="text-lg font-semibold text-neutral-50 mb-3"
      >
        A known allowance, billed monthly
      </h2>
      <p class="max-w-2xl text-sm text-neutral-400 leading-relaxed mb-5">
        A plan raises your key's rate limit, and the key itself stays the same.
        Your use is shown against the allowance, and nothing is billed beyond the plan's price.
      </p>
      <ul
        role="list"
        class="grid grid-cols-1 md:grid-cols-3 gap-4"
      >
        <li
          :for={plan <- @plans}
          id={"plan-#{plan.id}"}
          class="bg-surface-raised rounded p-6 border border-neutral-800 flex flex-col"
        >
          <h3 class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-2">
            {plan.name}
          </h3>
          <p class="flex items-baseline gap-1 mb-4">
            <span class="text-3xl font-semibold text-neutral-50">
              {cents(plan.price_cents)}
            </span>
            <span class="text-sm text-neutral-500">a month</span>
          </p>
          <dl class="border-t border-neutral-800 mb-6">
            <div class="py-2.5 border-b border-neutral-800 flex justify-between gap-4">
              <dt class="text-sm text-neutral-400">API requests</dt>
              <dd class="font-mono text-sm text-neutral-50">
                {number(plan.requests_per_minute)}/min
              </dd>
            </div>
            <div class="py-2.5 border-b border-neutral-800 flex justify-between gap-4">
              <dt class="text-sm text-neutral-400">Requests a month</dt>
              <dd class="font-mono text-sm text-neutral-50">
                {number(plan.monthly_requests)}
              </dd>
            </div>
            <div class="py-2.5 border-b border-neutral-800 flex justify-between gap-4">
              <dt class="text-sm text-neutral-400">Data a month</dt>
              <dd class="font-mono text-sm text-neutral-50">
                {number(plan.monthly_gib)} GiB
              </dd>
            </div>
          </dl>
          <div class="mt-auto">
            <button
              :if={@current_user && !@subscribed}
              id={"plan-#{plan.id}-choose"}
              type="button"
              phx-click="choose_plan"
              phx-value-plan={plan.id}
              phx-disable-with="Opening Stripe..."
              aria-label={"Choose #{plan.name}"}
              class="w-full px-6 py-3 bg-brand-strong text-white font-medium rounded hover:opacity-90 transition-colors"
            >
              Choose
            </button>
            <.link
              :if={!@current_user}
              id={"plan-#{plan.id}-sign-in"}
              navigate="/sign-in"
              class="block w-full px-6 py-3 border border-neutral-700 text-neutral-50 font-medium rounded hover:bg-neutral-800 transition-colors text-center"
            >
              Sign in to choose
            </.link>
          </div>
        </li>
      </ul>
      <p
        :if={@subscribed}
        id="plans-subscribed"
        class="mt-4 text-sm text-neutral-400"
      >
        You have a plan.
        Change or cancel it from "Manage billing" under
        <a
          href="#plan"
          class="text-neutral-50 underline underline-offset-2"
        >
          Your plan</a>.
      </p>
      <p
        :if={@error}
        id="plans-error"
        role="alert"
        class="mt-4 text-sm text-neutral-50"
      >
        {@error}
      </p>
      <p class="mt-4 text-xs text-neutral-500">
        Prices in US dollars, paid by card through Stripe.
        Need more?
        The custom plan below is a quote from us.
      </p>
    </section>
    """
  end

  attr :subscription, :any, default: nil
  attr :usage, :any, default: nil
  attr :pending, :boolean, default: false
  attr :can_manage, :boolean, default: false
  attr :contact_email, :string, required: true
  attr :error, :string, default: nil

  @doc "\"Your plan\": the plan, its status and renewal, this period's use against the allowance, and billing."
  def your_plan(assigns) do
    assigns =
      assign(assigns, :state, assigns.subscription && Billing.state(assigns.subscription))

    ~H"""
    <section
      :if={@subscription || @pending}
      id="plan"
      aria-labelledby="plan-heading"
      class="border-t border-neutral-800 py-8 scroll-mt-6"
    >
      <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-2">
        Your plan
      </p>
      <h2
        id="plan-heading"
        class="text-lg font-semibold text-neutral-50 mb-3"
      >
        {if @subscription, do: @subscription.plan_name, else: "Your plan"}
      </h2>

      <p
        :if={@pending && !@subscription}
        id="plan-pending"
        role="status"
        class="text-sm text-neutral-400"
      >
        Waiting for Stripe to confirm your subscription.
        This page updates when it does, usually within a minute.
      </p>

      <div
        :if={@subscription}
        class="bg-surface-raised rounded p-6 border border-neutral-800 max-w-2xl"
      >
        <dl class="border-t border-neutral-800 mb-5">
          <div class="py-2.5 border-b border-neutral-800 flex justify-between gap-4">
            <dt class="text-sm text-neutral-400">Status</dt>
            <dd
              id="plan-status"
              class="text-sm text-neutral-50 text-right"
            >
              {status_label(@state)}
            </dd>
          </div>
          <div class="py-2.5 border-b border-neutral-800 flex justify-between gap-4">
            <dt class="text-sm text-neutral-400">Price</dt>
            <dd class="font-mono text-sm text-neutral-50">
              {cents(@subscription.price_cents)} a month
            </dd>
          </div>
          <div class="py-2.5 border-b border-neutral-800 flex justify-between gap-4">
            <dt class="text-sm text-neutral-400">Your key's limit</dt>
            <dd
              id="plan-rate"
              class="font-mono text-sm text-neutral-50"
            >
              {number(
                if @state == :ended,
                  do: Billing.trial_requests_per_minute(),
                  else: @subscription.requests_per_minute
              )}/min
            </dd>
          </div>
          <div
            :if={@subscription.current_period_end && @state != :ended}
            class="py-2.5 border-b border-neutral-800 flex justify-between gap-4"
          >
            <dt class="text-sm text-neutral-400">
              {if @state == :canceling, do: "Ends", else: "Renews"}
            </dt>
            <dd
              id="plan-renews"
              class="text-sm text-neutral-50"
            >
              {date(@subscription.current_period_end)}
            </dd>
          </div>
        </dl>

        <p
          :if={@state == :past_due}
          id="plan-past-due"
          role="alert"
          class="text-sm text-neutral-50 mb-4"
        >
          Your last payment didn't go through, and Stripe is trying again.
          Your key keeps the plan's limit meanwhile.
          Update your card from "Manage billing" to keep it.
        </p>
        <p
          :if={@state == :ended}
          id="plan-ended"
          class="text-sm text-neutral-400 mb-4"
        >
          This plan has ended, so your key is back to the trial's limit.
          Choose a plan above to raise it again.
        </p>

        <div
          :if={@state != :ended}
          id="plan-usage"
        >
          <h3 class="text-sm font-medium text-neutral-50 mb-2">
            This period's use
          </h3>
          <p
            :if={is_nil(@usage)}
            class="text-sm text-neutral-500"
          >
            Loading your use...
          </p>
          <p
            :if={@usage == :unavailable}
            class="text-sm text-neutral-50"
          >
            Your use is unavailable right now. Try again shortly.
          </p>
          <div
            :if={is_map(@usage)}
            class="space-y-3"
          >
            <.allowance_meter
              id="plan-usage-requests"
              label="Requests"
              used={number(@usage.requests)}
              allowance={number(@usage.allowance_requests)}
              percent={@usage.requests_percent}
            />
            <.allowance_meter
              id="plan-usage-bytes"
              label="Data sent"
              used={Usage.format_bytes(@usage.bytes)}
              allowance={"#{number(@subscription.monthly_gib)} GiB"}
              percent={@usage.bytes_percent}
            />
            <p class="text-xs text-neutral-500">
              Since {date(@usage.from)}, through your key.
              Counts reach this view within a minute.
            </p>
            <p
              :if={@usage.level == :near}
              id="plan-usage-near"
              role="status"
              class="text-sm text-neutral-50"
            >
              You've used 80% or more of this period's allowance.
            </p>
            <p
              :if={@usage.level == :over}
              id="plan-usage-over"
              role="status"
              class="text-sm text-neutral-50"
            >
              You've used this period's allowance.
              Your key keeps the plan's rate, and nothing more is billed.
              If this is your usual traffic, a larger plan or a custom one fits better.
            </p>
          </div>
        </div>

        <div class="mt-5 flex flex-col sm:flex-row sm:items-center gap-3">
          <button
            :if={@can_manage}
            id="plan-manage"
            type="button"
            phx-click="manage_billing"
            phx-disable-with="Opening Stripe..."
            class="shrink-0 px-6 py-3 bg-brand-strong text-white font-medium rounded hover:opacity-90 transition-colors"
          >
            Manage billing
          </button>
          <a
            id="plan-contact"
            href={"mailto:#{@contact_email}?subject=#{URI.encode("Bitblocks plan: " <> @subscription.plan_name)}"}
            class="shrink-0 px-6 py-3 border border-neutral-700 text-neutral-50 font-medium rounded hover:bg-neutral-800 transition-colors text-center"
          >
            Contact us
          </a>
        </div>
        <p
          :if={@error}
          id="plan-error"
          role="alert"
          class="mt-3 text-sm text-neutral-50"
        >
          {@error}
        </p>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :used, :string, required: true
  attr :allowance, :string, required: true
  attr :percent, :integer, required: true

  defp allowance_meter(assigns) do
    ~H"""
    <div id={@id}>
      <div class="flex justify-between gap-4 text-sm mb-1">
        <span
          id={"#{@id}-label"}
          class="text-neutral-400"
        >
          {@label}
        </span>
        <span class="font-mono text-neutral-50 tabular-nums">
          {@used} of {@allowance} ({@percent}%)
        </span>
      </div>
      <div
        role="meter"
        aria-labelledby={"#{@id}-label"}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={min(@percent, 100)}
        aria-valuetext={"#{@percent}% of the allowance"}
        class="h-2 rounded bg-neutral-800 overflow-hidden"
      >
        <div
          class={[
            "h-full rounded",
            if(@percent >= 100, do: "bg-red-500", else: "bg-brand-strong")
          ]}
          style={"width: #{min(@percent, 100)}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  defp status_label(:active), do: "Active"
  defp status_label(:canceling), do: "Active, cancels at the end of the period"
  defp status_label(:past_due), do: "Payment failed, Stripe is retrying"
  defp status_label(:ended), do: "Ended"

  defp cents(cents) when is_integer(cents),
    do: Downloads.format_usd(Decimal.div(Decimal.new(cents), 100))

  defp number(n), do: Downloads.format_number(n)

  defp date(%DateTime{} = dt), do: Calendar.strftime(dt, "%B %-d, %Y")
end
