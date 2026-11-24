defmodule BitblocksWeb.PricingLive do
  @moduledoc """
  `/pricing`: the plans, and (`#crawlers`) the way in for AI crawlers and data
  licensing, which the crawler 402 links to (`BitblocksWeb.Plugs.RateLimiter`,
  #107). Keys have no price yet (#61), so that section says to write to us;
  with x402 on, it also gives the per-request price and how to pay
  (`#crawlers-x402`), and with BSV 402 on, the same in satoshis
  (`#crawlers-bsv`, `Bitblocks.Payments.Bsv402`). Its budget, coverage and price are read when the page
  loads.

  `#downloads` quotes a bulk download of a block range (`Bitblocks.Downloads`,
  https://github.com/afomi/bitblocks/issues/111): size, file count and price
  from stored block sizes, bounded by `complete_through`, with the arithmetic
  shown (billable GiB x the price per GiB), and a "Contact us" that mails it.

  "Pay" buys the quote with Stripe Checkout (`Bitblocks.Downloads.Purchases`)
  for a signed-in user, once Checkout is configured
  (`Bitblocks.Payments.Stripe.configured?/0`); in Stripe's test mode only an
  admin sees it. The click quotes the range afresh on the server, stores the
  purchase, and sends the browser to Stripe; the price never comes from the
  browser. A range we can't serve (a block not in the file store, no exact
  price, under Stripe's smallest payment) says why instead of offering "Pay".
  Until Checkout is configured, the quote keeps "Contact us" alone.

  The estimate is live: each change to the form (debounced in the browser),
  each named range (`Downloads.presets/1`) and each band of the size view
  (`Downloads.size_bands/1`, loaded async and cached) asks for a quote. A
  socket still runs at most one quote per `quote_interval_ms/0`, since each
  is an aggregate over `blocks`: a request inside the interval waits for its
  end, and only the latest one runs.

  `#cloud` (`BitblocksWeb.PricingLive.CloudQuote`,
  https://github.com/afomi/bitblocks/issues/113) describes managed
  projections, filtered databases and dedicated instances, and requests a
  quote by mail with a filter spec and a bounded estimate. `#consulting`
  (https://github.com/afomi/bitblocks/issues/114) is a mailto, nothing more.

  `#usage` shows a signed-in user their own measured use (`Bitblocks.Usage`)
  over the last 24 hours: as themselves, and through their key. No API price
  is set yet (https://github.com/afomi/bitblocks/issues/61).

  `#plans` and `#plan` are monthly plans (`Bitblocks.Billing`,
  `BitblocksWeb.PlanComponents`, https://github.com/afomi/bitblocks/issues/112):
  dormant, and absent from the page, until plans are configured and Stripe
  is; in Stripe's test mode only an admin sees them.
  """
  use BitblocksWeb, :live_view

  require Logger

  alias Bitblocks.ApiKeys
  alias Bitblocks.Billing
  alias Bitblocks.Downloads
  alias Bitblocks.Downloads.Purchases
  alias Bitblocks.Payments.Stripe
  alias Bitblocks.SyncProgress
  alias Bitblocks.Usage
  alias BitblocksWeb.Plugs.RateLimiter
  alias BitblocksWeb.Plugs.RateLimiter.AiCrawlers
  alias BitblocksWeb.Seo
  alias BitblocksWeb.StartLive.Index

  @default_range 100_000
  @usage_hours 24

  @impl true
  def mount(params, _session, socket) do
    coverage = Index.coverage(SyncProgress.snapshot().overview)
    plan_params = if is_map(params), do: params, else: %{}
    params = quote_params(params, coverage)

    socket =
      socket
      |> assign(
        Seo.public_page(
          page_title: "Pricing",
          meta_description:
            "Bitblocks API pricing: start free, and pay for what you use as you grow. " <>
              "Bulk downloads of a block range at a published price per GiB, quoted for free.",
          canonical_path: "/pricing"
        )
      )
      |> assign(:crawler_budget, crawler_budget())
      |> assign(:anonymous_site_budget, anonymous_site_budget())
      |> assign(:ip_budget, ip_budget())
      |> assign(:signed_in_budget, RateLimiter.signed_in_max_requests())
      |> assign(:coverage, coverage)
      |> assign(:contact_email, AiCrawlers.contact_email())
      |> assign(:x402, x402())
      |> assign(:bsv402, bsv402())
      |> assign(:data_options, Downloads.data_options())
      |> assign(:price_per_gib, Downloads.price_usd_per_gib())
      |> assign(:holding, if(coverage, do: coverage.through, else: -1))
      |> assign(:sizes, nil)
      |> assign(:sizes_error, nil)
      |> assign(:quote_form, to_form(params, as: :quote))
      |> assign(:quote, nil)
      |> assign(:quote_error, nil)
      |> assign(:quoted_at, nil)
      |> assign(:pending_quote, nil)
      |> assign(:usage, nil)
      |> assign(:checkout, checkout_open?(socket))
      |> assign(:pay_error, nil)
      |> assign_plans(plan_params)

    if connected?(socket) do
      if user = socket.assigns[:current_user],
        do: Phoenix.PubSub.subscribe(Bitblocks.PubSub, Billing.topic(user.id))

      {:ok,
       socket
       |> start_async(:sizes, fn -> Downloads.size_bands() end)
       |> assign(:usage, own_usage(socket.assigns[:current_user]))
       |> assign_plan_usage()
       |> then(&if(coverage, do: request_quote(&1, params), else: &1))}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("quote_change", %{"quote" => params}, socket) do
    {:noreply,
     socket |> assign(:quote_form, to_form(params, as: :quote)) |> request_quote(params)}
  end

  def handle_event("quote", %{"quote" => params}, socket) do
    {:noreply,
     socket |> assign(:quote_form, to_form(params, as: :quote)) |> request_quote(params)}
  end

  def handle_event("preset", %{"id" => id}, socket) do
    case Downloads.preset(id, socket.assigns.holding) do
      %{available: true, from: from, to: to} -> {:noreply, quote_range(socket, from, to)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("band", %{"from" => from, "to" => to}, socket) do
    {:noreply, quote_range(socket, from, to)}
  end

  # Buys the range in the form, quoted afresh here: nothing the browser sends
  # but the range, data and format reaches the price.
  def handle_event("pay", _params, socket) do
    user = socket.assigns[:current_user]

    with true <- socket.assigns.checkout || {:error, :not_configured},
         {:ok, purchase} <- Purchases.create(user, socket.assigns.quote_form.params),
         {:ok, url} <- Purchases.start_checkout(purchase, BitblocksWeb.Endpoint.url()) do
      {:noreply, redirect(socket, external: url)}
    else
      {:error, reason} ->
        Logger.info("Download checkout not started: #{inspect(reason)}")
        {:noreply, assign(socket, :pay_error, pay_error(reason))}
    end
  end

  # Monthly plans (#112): only the plan id comes from the browser; its price
  # and limits are the server's config, and the row is the signed-in user's.
  def handle_event("choose_plan", %{"plan" => plan_id}, socket) do
    user = socket.assigns[:current_user]

    with true <- socket.assigns.plans_for_sale || {:error, :not_configured},
         {:ok, url} <- Billing.choose(user, plan_id, BitblocksWeb.Endpoint.url()) do
      {:noreply, redirect(socket, external: url)}
    else
      {:error, reason} ->
        Logger.info("Plan checkout not started: #{inspect(reason)}")
        {:noreply, assign(socket, :plans_error, Billing.refusal_message(reason))}
    end
  end

  def handle_event("manage_billing", _params, socket) do
    case socket.assigns[:current_user] &&
           Billing.portal_url(socket.assigns.current_user, BitblocksWeb.Endpoint.url()) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      other ->
        Logger.info("Billing portal not opened: #{inspect(other)}")
        reason = with {:error, r} <- other, do: r
        {:noreply, assign(socket, :plan_error, Billing.refusal_message(reason))}
    end
  end

  @impl true
  def handle_info({:plan_subscription, _row}, socket) do
    {:noreply, socket |> assign_plans(%{}) |> assign(:plan_pending, false) |> assign_plan_usage()}
  end

  def handle_info(:run_pending_quote, socket) do
    case socket.assigns.pending_quote do
      nil -> {:noreply, socket}
      params -> {:noreply, socket |> assign(:pending_quote, nil) |> run_quote(params)}
    end
  end

  @impl true
  def handle_async(:sizes, {:ok, sizes}, socket) do
    {:noreply, assign(socket, sizes: sizes, holding: sizes.complete_through)}
  end

  def handle_async(:sizes, {:exit, reason}, socket) do
    Logger.warning("Download size bands failed: #{inspect(reason)}")
    {:noreply, assign(socket, :sizes_error, "Sizes by range are unavailable right now.")}
  end

  # Sets the form's range, keeping the data and format, and asks for a quote.
  defp quote_range(socket, from, to) do
    params =
      socket.assigns.quote_form.params
      |> Map.merge(%{"from" => to_string(from), "to" => to_string(to)})

    socket |> assign(:quote_form, to_form(params, as: :quote)) |> request_quote(params)
  end

  # At most one quote per interval: inside it, the latest params wait for its end.
  defp request_quote(socket, params) do
    now = System.monotonic_time(:millisecond)
    since = socket.assigns.quoted_at && now - socket.assigns.quoted_at
    interval = quote_interval_ms()

    cond do
      is_nil(since) or since >= interval ->
        socket |> assign(:pending_quote, nil) |> run_quote(params)

      socket.assigns.pending_quote ->
        assign(socket, :pending_quote, params)

      true ->
        Process.send_after(self(), :run_pending_quote, interval - since)
        assign(socket, :pending_quote, params)
    end
  end

  defp run_quote(socket, params) do
    socket = assign(socket, :quoted_at, System.monotonic_time(:millisecond))

    case quote_or_unavailable(params) do
      {:ok, quote} ->
        assign(socket, quote: quote, quote_error: nil)

      {:error, :unavailable} ->
        assign(socket,
          quote: nil,
          quote_error: "Quotes are unavailable right now. Try again shortly."
        )

      {:error, reason} ->
        assign(socket, quote: nil, quote_error: Downloads.error_message(reason))
    end
  end

  @doc """
  Milliseconds between two quotes on one socket:
  `config :bitblocks, :downloads_quote_interval_ms`, 1,000 by default.
  """
  def quote_interval_ms, do: Application.get_env(:bitblocks, :downloads_quote_interval_ms, 1_000)

  # A signed-in user's own use over the last day: as themselves, and through
  # their key, if they hold one. Two small queries over the rollups.
  defp own_usage(%{id: id} = user) do
    key = ApiKeys.trial_key(user)

    %{
      hours: @usage_hours,
      session: Usage.caller_usage({"user", to_string(id)}, hours: @usage_hours),
      key:
        key &&
          %{
            prefix: key.prefix,
            usage: Usage.caller_usage({"key", to_string(key.id)}, hours: @usage_hours)
          }
    }
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Own usage failed: #{Exception.message(error)}")
      :unavailable
  end

  defp own_usage(_), do: nil

  # The plans on offer and the user's own plan. With none configured, or
  # Stripe not configured, plans_for_sale is false and #plans renders nothing.
  defp assign_plans(socket, params) do
    user = socket.assigns[:current_user]
    subscription = user && Billing.subscription_for_view(user)

    pending =
      case user && Billing.get_for_user(params["plan_checkout"], user) do
        %{status: "checkout_open"} -> true
        _ -> Map.get(socket.assigns, :plan_pending, false) and is_nil(subscription)
      end

    assign(socket,
      plans: Billing.plans(),
      plans_for_sale: Billing.for_sale?(socket.assigns[:admin?] == true),
      plan_subscription: subscription,
      plan_entitled: subscription != nil and Billing.entitled?(subscription),
      plan_can_manage:
        subscription != nil and is_binary(subscription.stripe_customer_id) and
          Stripe.configured?(),
      plan_pending: pending,
      plans_error: Map.get(socket.assigns, :plans_error),
      plan_error: Map.get(socket.assigns, :plan_error),
      plan_usage: Map.get(socket.assigns, :plan_usage)
    )
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Plans failed: #{Exception.message(error)}")

      assign(socket,
        plans: [],
        plans_for_sale: false,
        plan_subscription: nil,
        plan_entitled: false,
        plan_can_manage: false,
        plan_pending: false,
        plans_error: nil,
        plan_error: nil,
        plan_usage: nil
      )
  end

  defp assign_plan_usage(%{assigns: %{plan_subscription: %{} = s}} = socket) do
    usage =
      try do
        Billing.period_usage(s)
      rescue
        error in [DBConnection.ConnectionError, Postgrex.Error] ->
          Logger.warning("Plan usage failed: #{Exception.message(error)}")
          :unavailable
      end

    assign(socket, :plan_usage, usage)
  end

  defp assign_plan_usage(socket), do: socket

  @doc "The usage tables to show: as the signed-in user, then through their key."
  def usage_groups(%{session: session, key: key}) do
    [{"As you, signed in", "usage-session", session}] ++
      if(key, do: [{"Your key #{key.prefix}...", "usage-key", key.usage}], else: [])
  end

  @doc "An endpoint class in plain words, for the usage table."
  def class_label("read"), do: "API reads"
  def class_label("raw_export"), do: "Raw bytes and exports"
  def class_label("stream"), do: "Streams"
  def class_label("proof"), do: "Proofs and BEEF"
  def class_label("ops"), do: "Ops"
  def class_label("page"), do: "Pages"
  def class_label(other), do: other

  @doc "The band's share of the largest band, as a CSS width, at least 1% when it holds bytes."
  def band_width(_bytes, 0), do: "0%"
  def band_width(0, _max), do: "0%"
  def band_width(bytes, max), do: "#{max(Float.round(bytes / max * 100, 1), 1.0)}%"

  @doc "The largest band's bytes."
  def max_band_bytes(%{bands: bands}), do: bands |> Enum.map(& &1.bytes) |> Enum.max(fn -> 0 end)

  defdelegate format_usd(amount), to: Downloads
  defdelegate format_bytes(n), to: Usage

  # A slow or failed query says so on the page rather than crashing it.
  defp quote_or_unavailable(params) do
    Downloads.quote(params["from"], params["to"], params["data"], format: params["format"])
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Downloads quote failed: #{Exception.message(error)}")
      {:error, :unavailable}
  end

  # Stripe Checkout is open to this visitor: configured, and in test mode
  # (sandbox) only for an admin, so nobody buys real files with a test card.
  defp checkout_open?(socket) do
    Stripe.configured?() and (Stripe.mode() == "live" or socket.assigns[:admin?] == true)
  end

  defp pay_error(reason) when is_atom(reason) or is_tuple(reason) do
    case reason do
      {:stripe_error, _, _, _} -> "Stripe couldn't open checkout just now. Try again shortly."
      :stripe_unavailable -> "Stripe couldn't open checkout just now. Try again shortly."
      :invalid_response -> "Stripe couldn't open checkout just now. Try again shortly."
      {:not_configured, _} -> Purchases.refusal_message(:not_configured)
      other -> Purchases.refusal_message(other)
    end
  end

  defp pay_error(_), do: "Checkout couldn't start. Try again shortly."

  @doc "Whether this quote can be bought online, or why not (`Purchases.purchasable/1`)."
  def purchasable(quote), do: Purchases.purchasable(quote)

  defdelegate refusal_message(reason), to: Purchases

  @doc "/pricing with this quote's range, to come back to after signing in."
  def quote_path(quote) do
    "/pricing?" <>
      URI.encode_query(%{from: quote.from, to: quote.to, data: quote.data, format: quote.format})
  end

  # The range from the URL (a cancelled checkout comes back with it), else
  # blocks 0 to 99,999, or as far as the complete blocks reach.
  defp quote_params(%{"from" => from, "to" => to} = params, _coverage)
       when is_binary(from) and is_binary(to) do
    %{
      "from" => from,
      "to" => to,
      "data" => Map.get(params, "data", "raw"),
      "format" => Map.get(params, "format", "bin")
    }
  end

  defp quote_params(_params, coverage), do: default_quote_params(coverage)

  defp default_quote_params(coverage) do
    to =
      case coverage do
        %{through: through} -> min(through, @default_range - 1)
        nil -> @default_range - 1
      end

    %{"from" => "0", "to" => Integer.to_string(to), "data" => "raw", "format" => "bin"}
  end

  @doc "The formats a data option comes in, for the format select."
  def formats_for(options, data) do
    case Enum.find(options, &(&1.id == data)) do
      %{formats: formats} -> Enum.filter(formats, & &1.available)
      nil -> []
    end
  end

  @doc "The mailto for a quote: our address, with the quote in the subject and body."
  def quote_mailto(email, quote) do
    subject = "Bulk download quote: blocks #{quote.from} to #{quote.to}"

    body =
      Enum.join(
        [
          "Blocks: #{format_number(quote.from)} to #{format_number(quote.to)}",
          "Data: #{quote.data}, format: #{quote.format}",
          "Files: #{format_number(quote.files)}",
          "Size: #{format_number(quote.bytes)} bytes (#{format_gib(quote.bytes)} GiB)",
          "Price: #{price_line(quote)}",
          "Complete through: #{format_number(quote.complete_through)}"
        ],
        "\n"
      )

    "mailto:#{email}?" <> URI.encode_query(%{subject: subject, body: body}, :rfc3986)
  end

  @doc """
  The mailto for consulting (https://github.com/afomi/bitblocks/issues/114):
  our address with the subject set, and a body asking what a scope needs.
  Consulting is through Civic Studio, quoted and invoiced there, so it has
  no Checkout, plan or key here.
  """
  def consulting_mailto(email) do
    body =
      Enum.join(
        [
          "Organization:",
          "What you're building:",
          "What you need from us:",
          "A scoped project, or a block of technical hours:",
          "Timeline:"
        ],
        "\n"
      )

    "mailto:#{email}?" <>
      URI.encode_query(%{subject: "Consulting enquiry", body: body}, :rfc3986)
  end

  @doc """
  The price as the quote shows it, with its arithmetic:
  "2.50 GiB x $1.00 per GiB = $2.50", or why there is none.
  """
  def price_line(%{price_usd: %Decimal{} = price} = quote) do
    "#{Decimal.to_string(quote.billable_gib, :normal)} GiB x " <>
      "#{format_usd(quote.price_usd_per_gib)} per GiB = #{format_usd(price)}"
  end

  def price_line(%{price_usd_per_gib: %Decimal{} = per_gib}),
    do: "on request (some sizes are missing; #{format_usd(per_gib)} per GiB once known)"

  def price_line(_quote), do: "on request"

  @doc """
  Bytes as GiB with two decimals, rounded half up as the price is, and a
  floor so a small range doesn't read as zero.
  """
  def format_gib(0), do: "0"

  def format_gib(bytes) when bytes * 200 < 1_073_741_824, do: "< 0.01"

  def format_gib(bytes) do
    [whole, fraction] =
      bytes
      |> Downloads.billable_gib()
      |> Decimal.to_string(:normal)
      |> String.split(".")

    format_number(String.to_integer(whole)) <> "." <> fraction
  end

  @doc """
  What the x402 offer is, for `#crawlers-x402`, or nil while x402 is off
  (`Bitblocks.Payments.X402.enabled?/0`), so no price shows that can't be paid.
  """
  def x402 do
    alias Bitblocks.Payments.X402, as: Pay

    if Pay.enabled?() do
      %{
        price: Pay.price_usdc(),
        network: Pay.network(),
        network_name: Pay.network_name(Pay.network())
      }
    end
  end

  @doc """
  What the BSV offer is, for `#crawlers-bsv`, or nil while BSV 402 is off
  (`Bitblocks.Payments.Bsv402.enabled?/0`), so no price shows that can't be paid.
  """
  def bsv402 do
    alias Bitblocks.Payments.Bsv402

    if Bsv402.enabled?() do
      %{price_sats: Bsv402.price_sats(), server_key: Bsv402.identity_public()}
    end
  end

  @doc "Requests a minute an AI crawler family shares without a key."
  def crawler_budget do
    Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, [])
    |> Keyword.get(:ai_crawler_max_requests, 10)
  end

  @doc "Requests a minute everyone with no key and no session shares, or nil while that's off."
  def anonymous_site_budget do
    case RateLimiter.anonymous_site_max_requests() do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc "Requests a minute one address has without a key or a session."
  def ip_budget do
    Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, [])
    |> Keyword.get(:max_requests, 30)
  end

  defdelegate format_number(n), to: Index
end
