defmodule Bitblocks.Billing do
  @moduledoc """
  Monthly plans: a signed-in user subscribes with Stripe Checkout, and their
  key's limit moves to the plan's without the key changing
  (https://github.com/afomi/bitblocks/issues/112, docs/STRIPE.md).

  Built dormant: with no plans configured, or Stripe not configured, nothing
  is offered and `/pricing` reads as it did.

  ## Plans are config

  `config :bitblocks, Bitblocks.Billing, plans: [...]` (a list of maps), or
  `plans_json:` (the same list as JSON; prod reads it from `BILLING_PLANS`,
  so no price is ever in this repo). Each plan:

  | Field | What it is |
  | --- | --- |
  | `id` | a slug, `[a-z0-9_-]`, up to 32 |
  | `name` | what `/pricing` calls it |
  | `price_cents` | the monthly price shown, in US cents |
  | `stripe_price_id` | the Stripe Price Checkout charges (`price_...`), monthly, the same amount |
  | `requests_per_minute` | the key's rate limit on the plan |
  | `monthly_requests` | the monthly allowance of API requests |
  | `monthly_gib` | the monthly allowance of data sent, in GiB |

  One plan that doesn't parse turns every plan off (`plans_status/0` says
  why), so a typo never sells something half-set.

  The page shows `price_cents`; Stripe charges the Price. They must agree,
  and each subscription event that carries the Price's amount is checked
  against it (a mismatch is logged, and the subscriber keeps the plan they paid for).

  ## The life of a subscription

    1. `choose/3` stores a `checkout_open` row for the user and the plan,
       with the plan's limits copied onto it, and opens one Checkout session
       in subscription mode for the plan's Price (idempotency key: the row's
       id). Only the plan id comes from the browser.
    2. Only signed webhooks change it (`apply_stripe_event/3`, through
       `Bitblocks.Payments.StripeEvents`): `checkout.session.completed`
       makes it `subscribed`; `customer.subscription.created`, `.updated`
       and `.deleted` copy the subscription's own status and period; an
       `invoice.paid` or `invoice.payment_failed` moves it between active and
       past due. An event older than the newest one applied (its `created`)
       changes nothing, so they can arrive in any order.
    3. After every change, the user's keys get the limit of their best
       entitled plan, or the trial's (`sync_keys/1`), and this node's key
       cache forgets them; other nodes within the cache's minute.

  A plan is entitled while Stripe says `active`, `trialing` or `past_due`:
  a failed payment keeps the limit through Stripe's retries. When Stripe
  gives up (`unpaid`, `canceled`) or the subscription ends, the key goes
  back to the trial's limit.

  The allowance is shown, never enforced with a surprise: at 100% the key
  keeps the plan's rate, and the page says so. Nothing is billed as overage.
  """

  import Ecto.Query

  require Logger

  alias Bitblocks.Accounts.User
  alias Bitblocks.ApiKeys
  alias Bitblocks.ApiKeys.ApiKey
  alias Bitblocks.Billing.PlanSubscription
  alias Bitblocks.Payments.Stripe
  alias Bitblocks.Repo
  alias Bitblocks.Usage

  @entitled ~w(active trialing past_due)
  @gib 1_073_741_824

  @type plan :: %{
          id: String.t(),
          name: String.t(),
          price_cents: pos_integer(),
          stripe_price_id: String.t(),
          requests_per_minute: pos_integer(),
          monthly_requests: pos_integer(),
          monthly_gib: pos_integer()
        }

  # ---------------------------------------------------------------------------
  # Plans

  @doc "The configured plans, cheapest first; `[]` when none, or when any is invalid."
  @spec plans() :: [plan()]
  def plans do
    case load_plans() do
      {:ok, plans} -> plans
      {:error, _} -> []
    end
  end

  @doc """
  `{:ok, plans}`, or `{:error, reason}` naming the first problem, for
  `Release.plans_status/0`. `{:ok, []}` when none are configured.
  """
  @spec load_plans() :: {:ok, [plan()]} | {:error, String.t()}
  def load_plans do
    config = Application.get_env(:bitblocks, __MODULE__, [])

    raw =
      case Keyword.get(config, :plans) do
        list when is_list(list) -> {:ok, list}
        nil -> decode_json(Keyword.get(config, :plans_json))
        _ -> {:error, "plans must be a list"}
      end

    with {:ok, list} <- raw, do: parse_plans(list)
  end

  defp decode_json(nil), do: {:ok, []}
  defp decode_json(""), do: {:ok, []}

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:error, "BILLING_PLANS must be a JSON array"}
      {:error, _} -> {:error, "BILLING_PLANS is not valid JSON"}
    end
  end

  @doc false
  def parse_plans(list) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, n}, {:ok, acc} ->
      case parse_plan(raw) do
        {:ok, plan} -> {:cont, {:ok, [plan | acc]}}
        {:error, why} -> {:halt, {:error, "plan #{n}: #{why}"}}
      end
    end)
    |> case do
      {:ok, plans} ->
        plans = Enum.sort_by(plans, & &1.price_cents)

        cond do
          dupes?(plans, :id) -> {:error, "two plans share an id"}
          dupes?(plans, :stripe_price_id) -> {:error, "two plans share a stripe_price_id"}
          true -> {:ok, plans}
        end

      error ->
        error
    end
  end

  defp dupes?(plans, field), do: length(Enum.uniq_by(plans, &Map.get(&1, field))) != length(plans)

  defp parse_plan(%{} = raw) do
    m = Map.new(raw, fn {k, v} -> {to_string(k), v} end)

    checks = [
      {"id", &(is_binary(&1) and &1 =~ ~r/\A[a-z0-9][a-z0-9_-]{0,31}\z/)},
      {"name", &(is_binary(&1) and String.length(String.trim(&1)) in 1..40)},
      {"price_cents", &(is_integer(&1) and &1 >= 50 and &1 <= 10_000_000)},
      {"stripe_price_id", &(is_binary(&1) and &1 =~ ~r/\Aprice_[A-Za-z0-9]{1,64}\z/)},
      {"requests_per_minute", &(is_integer(&1) and &1 >= 1 and &1 <= 100_000)},
      {"monthly_requests", &(is_integer(&1) and &1 >= 1)},
      {"monthly_gib", &(is_integer(&1) and &1 >= 1)}
    ]

    case Enum.find(checks, fn {field, ok?} -> not ok?.(m[field]) end) do
      nil ->
        {:ok,
         %{
           id: m["id"],
           name: String.trim(m["name"]),
           price_cents: m["price_cents"],
           stripe_price_id: m["stripe_price_id"],
           requests_per_minute: m["requests_per_minute"],
           monthly_requests: m["monthly_requests"],
           monthly_gib: m["monthly_gib"]
         }}

      {field, _} ->
        {:error, "#{field} is missing or invalid"}
    end
  end

  defp parse_plan(_), do: {:error, "not an object"}

  @doc "A configured plan by id, or nil."
  @spec plan(term()) :: plan() | nil
  def plan(id) when is_binary(id), do: Enum.find(plans(), &(&1.id == id))
  def plan(_), do: nil

  defp plan_for_price(price_id), do: Enum.find(plans(), &(&1.stripe_price_id == price_id))

  @doc """
  Whether plans can be bought by this visitor: some configured, Stripe
  configured, and in Stripe's test mode only for an admin, so nobody pays a
  real plan with a test card and no test price shows to the public.
  """
  @spec for_sale?(boolean()) :: boolean()
  def for_sale?(admin?) do
    plans() != [] and Stripe.configured?() and (Stripe.mode() == "live" or admin? == true)
  end

  @doc "The requests a minute a trial key gets, and a key with no entitled plan."
  def trial_requests_per_minute, do: ApiKeys.trial_requests_per_minute()

  # ---------------------------------------------------------------------------
  # Choosing a plan

  @doc """
  Starts (or reopens) Checkout for `plan_id` for `user`. `base_url` is our
  own origin (`BitblocksWeb.Endpoint.url/0`), so Stripe only sends the
  buyer back to us. Returns `{:ok, checkout_url}` or `{:error, reason}`:
  `:not_signed_in`, `:not_configured`, `:unknown_plan`, `:already_subscribed`,
  or Stripe's refusal.
  """
  @spec choose(User.t() | nil, term(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def choose(%User{} = user, plan_id, base_url) do
    with :ok <- if(Stripe.configured?(), do: :ok, else: {:error, :not_configured}),
         %{} = plan <- plan(plan_id) || {:error, :unknown_plan},
         nil <- if(entitled_subscription(user), do: {:error, :already_subscribed}),
         {:ok, row} <- open_or_insert(user, plan) do
      start_checkout(row, user, base_url)
    end
  end

  def choose(_user, _plan_id, _base_url), do: {:error, :not_signed_in}

  # A second "Choose" on the same plan inside Checkout's day reopens it.
  defp open_or_insert(user, plan) do
    since = DateTime.add(now(), -23 * 3_600)

    open =
      Repo.one(
        from(s in PlanSubscription,
          where:
            s.user_id == ^user.id and s.status == "checkout_open" and s.plan_id == ^plan.id and
              s.stripe_price_id == ^plan.stripe_price_id and s.stripe_mode == ^Stripe.mode() and
              s.inserted_at > ^since,
          order_by: [desc: s.inserted_at],
          limit: 1
        )
      )

    if open do
      {:ok, open}
    else
      %PlanSubscription{user_id: user.id, status: "checkout_open", stripe_mode: Stripe.mode()}
      |> struct(snapshot(plan))
      |> Repo.insert()
    end
  end

  defp snapshot(plan) do
    %{
      plan_id: plan.id,
      plan_name: plan.name,
      stripe_price_id: plan.stripe_price_id,
      price_cents: plan.price_cents,
      requests_per_minute: plan.requests_per_minute,
      monthly_requests: plan.monthly_requests,
      monthly_gib: plan.monthly_gib
    }
  end

  defp start_checkout(%PlanSubscription{stripe_checkout_url: "https://" <> _ = url}, _, _),
    do: {:ok, url}

  defp start_checkout(row, user, base_url) do
    params = %{
      price_id: row.stripe_price_id,
      success_url:
        base_url <> "/pricing?" <> URI.encode_query(%{plan_checkout: row.id}) <> "#plan",
      cancel_url: base_url <> "/pricing#plans",
      client_reference_id: row.id,
      customer: known_customer(user),
      metadata: %{plan_subscription_id: row.id, plan_id: row.plan_id, user_id: user.id}
    }

    case Stripe.create_subscription_checkout(params, row.id) do
      {:ok, %{id: session_id, url: url}} ->
        row
        |> Ecto.Changeset.change(stripe_session_id: session_id, stripe_checkout_url: url)
        |> Repo.update()
        |> case do
          {:ok, _} -> {:ok, url}
          error -> error
        end

      # Stripe keeps a refused request's answer under its idempotency key for
      # a day, so this row can't succeed; the next "Choose" makes a new one.
      {:error, {:stripe_error, status, _, _}} = error when status in 400..499 ->
        update!(row, status: "failed")
        error

      error ->
        error
    end
  end

  # The Stripe customer we already hold for this user in this mode, so one
  # user stays one customer.
  defp known_customer(%User{id: id}) do
    Repo.one(
      from(s in PlanSubscription,
        where:
          s.user_id == ^id and s.stripe_mode == ^Stripe.mode() and
            not is_nil(s.stripe_customer_id),
        order_by: [desc: s.updated_at],
        limit: 1,
        select: s.stripe_customer_id
      )
    )
  end

  @doc """
  A customer portal URL for the user's billing, returning to `/pricing#plan`.
  `{:error, :no_customer}` before Stripe has named their customer.
  """
  @spec portal_url(User.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def portal_url(%User{} = user, base_url) do
    case known_customer(user) do
      nil ->
        {:error, :no_customer}

      customer ->
        with {:ok, %{url: url}} <-
               Stripe.create_portal_session(customer, base_url <> "/pricing#plan"),
             do: {:ok, url}
    end
  end

  # ---------------------------------------------------------------------------
  # Reading a user's plan

  @doc "True when this row gives its limits now: subscribed, in this mode, and Stripe says active, trialing or past due."
  @spec entitled?(PlanSubscription.t()) :: boolean()
  def entitled?(%PlanSubscription{} = s) do
    s.status == "subscribed" and s.stripe_status in @entitled and s.stripe_mode == Stripe.mode()
  end

  @doc "The user's entitled subscription with the highest limit, or nil."
  @spec entitled_subscription(User.t() | integer()) :: PlanSubscription.t() | nil
  def entitled_subscription(%User{id: id}), do: entitled_subscription(id)

  def entitled_subscription(user_id) when is_integer(user_id) do
    Repo.one(
      from(s in PlanSubscription,
        where:
          s.user_id == ^user_id and s.status == "subscribed" and s.stripe_status in @entitled and
            s.stripe_mode == ^Stripe.mode(),
        order_by: [desc: s.requests_per_minute, desc: s.updated_at],
        limit: 1
      )
    )
  end

  @doc """
  The plan to show the user on "Your plan": their entitled one, else their
  latest subscription in this mode however it ended, else nil.
  """
  @spec subscription_for_view(User.t()) :: PlanSubscription.t() | nil
  def subscription_for_view(%User{id: id} = user) do
    entitled_subscription(user) ||
      Repo.one(
        from(s in PlanSubscription,
          where:
            s.user_id == ^id and s.status == "subscribed" and s.stripe_mode == ^Stripe.mode(),
          order_by: [desc: s.updated_at],
          limit: 1
        )
      )
  end

  @doc "The user's own row by id (a Checkout they just came back from), or nil."
  @spec get_for_user(term(), User.t() | nil) :: PlanSubscription.t() | nil
  def get_for_user(id, %User{id: user_id}) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %PlanSubscription{user_id: ^user_id} = s <- Repo.get(PlanSubscription, uuid) do
      s
    else
      _ -> nil
    end
  end

  def get_for_user(_id, _user), do: nil

  @doc "Requests a minute a key owned by this user should have now."
  @spec key_requests_per_minute(User.t() | integer()) :: pos_integer()
  def key_requests_per_minute(user) do
    case entitled_subscription(user) do
      %PlanSubscription{requests_per_minute: rpm} -> max(rpm, trial_requests_per_minute())
      nil -> trial_requests_per_minute()
    end
  end

  @doc """
  Where the subscription stands, in one word for the page: `:active`,
  `:canceling` (active, ends at period end), `:past_due`, `:ended`.
  """
  @spec state(PlanSubscription.t()) :: atom()
  def state(%PlanSubscription{} = s) do
    cond do
      s.stripe_status == "past_due" -> :past_due
      s.stripe_status in ["active", "trialing"] and s.cancel_at_period_end -> :canceling
      s.stripe_status in ["active", "trialing"] -> :active
      true -> :ended
    end
  end

  @doc """
  This period's use through the user's keys against the plan's allowance:
  requests and bytes sent since the period began (the calendar month until
  Stripe has told us the period), each as a share of the allowance, and
  `level`: `:under`, `:near` (80% or more of either) or `:over` (100%).
  """
  @spec period_usage(PlanSubscription.t(), DateTime.t()) :: map()
  def period_usage(%PlanSubscription{} = s, now \\ DateTime.utc_now()) do
    from = s.current_period_start || month_start(now)
    from_unix = div(DateTime.to_unix(from), 3600) * 3600
    to_unix = div(DateTime.to_unix(now), 3600) * 3600 + 3600
    hours = max(div(to_unix - from_unix, 3600), 1)

    totals =
      s.user_id
      |> key_ids_since(from)
      |> Enum.map(&Usage.caller_usage({"key", to_string(&1)}, hours: hours).totals)

    requests = totals |> Enum.map(& &1.requests) |> Enum.sum()
    bytes = totals |> Enum.map(& &1.response_bytes) |> Enum.sum()
    allowance_bytes = s.monthly_gib * @gib
    requests_share = requests / s.monthly_requests
    bytes_share = bytes / allowance_bytes
    top = max(requests_share, bytes_share)

    %{
      from: DateTime.from_unix!(from_unix),
      requests: requests,
      bytes: bytes,
      allowance_requests: s.monthly_requests,
      allowance_bytes: allowance_bytes,
      requests_percent: percent(requests_share),
      bytes_percent: percent(bytes_share),
      level:
        cond do
          top >= 1.0 -> :over
          top >= 0.8 -> :near
          true -> :under
        end
    }
  end

  defp percent(share), do: min(round(share * 100), 999)

  # The user's keys that could have been used since `from`: active, or revoked after it.
  defp key_ids_since(user_id, from) do
    Repo.all(
      from(k in ApiKey,
        where: k.user_id == ^user_id and (is_nil(k.revoked_at) or k.revoked_at >= ^from),
        select: k.id
      )
    )
  end

  defp month_start(%DateTime{} = now) do
    {:ok, start} = DateTime.new(Date.beginning_of_month(DateTime.to_date(now)), ~T[00:00:00])
    start
  end

  @doc "The PubSub topic a user's plan changes are broadcast on, as `{:plan_subscription, row}`."
  def topic(user_id), do: "billing:user:#{user_id}"

  # ---------------------------------------------------------------------------
  # Stripe events

  @doc """
  Applies a plan's event inside `Bitblocks.Payments.StripeEvents`'s
  transaction, after its id was recorded. Returns `{outcome, row | nil}`.
  """
  @spec apply_stripe_event(String.t(), map(), DateTime.t()) ::
          {String.t(), PlanSubscription.t() | nil}
  def apply_stripe_event(type, event, now) do
    object = get_in(event, ["data", "object"]) || %{}
    created = if is_integer(event["created"]), do: event["created"], else: nil

    case apply_event(type, object, created, now) do
      {outcome, %PlanSubscription{} = row} ->
        sync_keys(row.user_id)
        {outcome, row}

      other ->
        other
    end
  end

  @doc "After the event's transaction commits: this node forgets the user's cached keys, and the page hears of it."
  def after_stripe_event(_outcome, %PlanSubscription{} = row) do
    ApiKeys.forget_user_keys(row.user_id)
    Phoenix.PubSub.broadcast(Bitblocks.PubSub, topic(row.user_id), {:plan_subscription, row})
    :ok
  end

  defp apply_event("checkout.session.completed", session, _created, _now) do
    case row_for_session(session) do
      nil ->
        {"unknown_plan_subscription", nil}

      %PlanSubscription{status: status} = row
      when status in ["checkout_open", "expired", "failed"] ->
        {"subscribed",
         update!(row,
           status: "subscribed",
           stripe_subscription_id: row.stripe_subscription_id || id_of(session["subscription"]),
           stripe_customer_id: row.stripe_customer_id || id_of(session["customer"]),
           # A subscription event may have said more already; never override it.
           stripe_status: row.stripe_status || checkout_status(session)
         )}

      %PlanSubscription{} = row ->
        # Subscribed already, by a subscription event that came first.
        if is_nil(row.stripe_customer_id) and id_of(session["customer"]),
          do: {"subscribed", update!(row, stripe_customer_id: id_of(session["customer"]))},
          else: {"no_change", nil}
    end
  end

  defp apply_event("checkout.session.expired", session, _created, _now) do
    case row_for_session(session) do
      %PlanSubscription{status: "checkout_open"} = row ->
        {"expired", update!(row, status: "expired")}

      nil ->
        {"unknown_plan_subscription", nil}

      _ ->
        {"no_change", nil}
    end
  end

  defp apply_event("customer.subscription." <> kind, sub, created, now) do
    with %PlanSubscription{} = row <- row_for_subscription(sub),
         :ok <- fresh(row, created),
         :ok <- first_state(kind, row, created) do
      status = if kind == "deleted", do: "canceled", else: string_or(sub["status"], "incomplete")

      changes =
        [
          status: "subscribed",
          stripe_subscription_id: id_of(sub["id"]),
          stripe_customer_id: id_of(sub["customer"]) || row.stripe_customer_id,
          stripe_status: status,
          current_period_start: period(sub, "current_period_start") || row.current_period_start,
          current_period_end: period(sub, "current_period_end") || row.current_period_end,
          cancel_at_period_end: sub["cancel_at_period_end"] == true,
          canceled_at:
            unix(sub["canceled_at"]) || if(status == "canceled", do: row.canceled_at || now),
          last_event_created: created || row.last_event_created
        ] ++ plan_change(row, sub)

      {status, update!(row, changes)}
    else
      nil -> {"unknown_subscription", nil}
      :stale -> {"stale", nil}
    end
  end

  defp apply_event("invoice." <> kind, invoice, created, _now)
       when kind in ["paid", "payment_failed"] do
    with %PlanSubscription{} = row <- row_for_subscription_id(invoice_subscription(invoice)),
         :ok <- fresh(row, created) do
      case {kind, row.stripe_status} do
        {"paid", s} when s in [nil, "incomplete", "past_due", "unpaid"] ->
          {"active",
           update!(row,
             status: "subscribed",
             stripe_status: "active",
             current_period_end: later(row.current_period_end, invoice_period_end(invoice)),
             last_event_created: created || row.last_event_created
           )}

        {"paid", _} ->
          {"no_change", nil}

        {"payment_failed", s} when s in ["active", "trialing"] ->
          {"past_due",
           update!(row,
             stripe_status: "past_due",
             last_event_created: created || row.last_event_created
           )}

        {"payment_failed", _} ->
          {"no_change", nil}
      end
    else
      nil -> {"unknown_subscription", nil}
      :stale -> {"stale", nil}
    end
  end

  defp apply_event(_type, _object, _created, _now), do: {"ignored", nil}

  # An event older than the newest applied changes nothing. Equal is fresh:
  # Stripe's `created` is in seconds, and events of one second are one change.
  defp fresh(%PlanSubscription{last_event_created: last}, created)
       when is_integer(last) and is_integer(created) and created < last,
       do: :stale

  defp fresh(_row, _created), do: :ok

  # `customer.subscription.created` is a subscription's first state, so any
  # event already applied in the same second is at least as new.
  defp first_state("created", %PlanSubscription{last_event_created: last}, created)
       when is_integer(last) and is_integer(created) and created <= last,
       do: :stale

  defp first_state(_kind, _row, _created), do: :ok

  defp checkout_status(%{"payment_status" => "paid"}), do: "active"
  defp checkout_status(%{"payment_status" => "no_payment_required"}), do: "active"
  defp checkout_status(_), do: "incomplete"

  # A change of Price (a plan switched in the customer portal) moves the row
  # to the plan with that Price and its limits. An unknown Price keeps the
  # terms the row has, and says so in the log.
  defp plan_change(row, sub) do
    price = first_item(sub)["price"] || %{}
    price_id = price["id"]

    cond do
      not is_binary(price_id) or price_id == row.stripe_price_id ->
        check_amount(row, price)
        []

      plan = plan_for_price(price_id) ->
        check_amount(%{row | price_cents: plan.price_cents}, price)
        Map.to_list(snapshot(plan))

      true ->
        Logger.error(
          "Plan subscription #{row.id}: Stripe moved it to a Price no plan names; keeping #{row.plan_id}'s limits"
        )

        []
    end
  end

  defp check_amount(row, %{"unit_amount" => amount}) when is_integer(amount) do
    if amount != row.price_cents do
      Logger.error(
        "Plan subscription #{row.id}: Stripe's Price is #{amount} cents a month, " <>
          "the page showed #{row.price_cents}; fix the plan's price_cents or its Price"
      )
    end
  end

  defp check_amount(_row, _price), do: :ok

  defp first_item(sub) do
    case get_in(sub, ["items", "data"]) do
      [item | _] when is_map(item) -> item
      _ -> %{}
    end
  end

  # API versions before 2025 put the period on the subscription; later ones
  # on each item. Read either.
  defp period(sub, field), do: unix(sub[field]) || unix(first_item(sub)[field])

  defp invoice_subscription(invoice) do
    id_of(invoice["subscription"]) ||
      id_of(get_in(invoice, ["parent", "subscription_details", "subscription"]))
  end

  defp invoice_period_end(invoice) do
    case get_in(invoice, ["lines", "data"]) do
      [line | _] when is_map(line) -> unix(get_in(line, ["period", "end"]))
      _ -> nil
    end
  end

  defp later(nil, b), do: b
  defp later(a, nil), do: a
  defp later(a, b), do: if(DateTime.compare(b, a) == :gt, do: b, else: a)

  # The session must be the one we made for that row: its
  # client_reference_id names the row, and its id is the one stored (or none
  # was stored yet, when saving Stripe's answer failed).
  defp row_for_session(%{"id" => "cs_" <> _ = session_id} = session) do
    with {:ok, id} <- Ecto.UUID.cast(session["client_reference_id"]),
         %PlanSubscription{} = row <- lock(id) do
      case row.stripe_session_id do
        ^session_id -> row
        nil -> update!(row, stripe_session_id: session_id)
        _other -> nil
      end
    else
      _ -> nil
    end
  end

  defp row_for_session(_), do: nil

  # By the subscription id we hold, else by the row id we put in its
  # metadata at Checkout (a subscription event that beat the Checkout event).
  defp row_for_subscription(%{"id" => "sub_" <> _ = sub_id} = sub) do
    row_for_subscription_id(sub_id) ||
      with {:ok, id} <- Ecto.UUID.cast(get_in(sub, ["metadata", "plan_subscription_id"])),
           %PlanSubscription{stripe_subscription_id: held} = row when held in [nil, sub_id] <-
             lock(id) do
        row
      else
        _ -> nil
      end
  end

  defp row_for_subscription(_), do: nil

  defp row_for_subscription_id("sub_" <> _ = sub_id) do
    Repo.one(
      from(s in PlanSubscription, where: s.stripe_subscription_id == ^sub_id, lock: "FOR UPDATE")
    )
  end

  defp row_for_subscription_id(_), do: nil

  defp lock(id), do: Repo.one(from(s in PlanSubscription, where: s.id == ^id, lock: "FOR UPDATE"))

  # ---------------------------------------------------------------------------
  # Keys

  @doc """
  Gives every active key the user owns the limit of their best entitled
  plan, or the trial's. The key's secret never changes. Returns the number
  of keys changed. Callers forget the cached keys after their transaction
  (`ApiKeys.forget_user_keys/1`).
  """
  @spec sync_keys(integer()) :: non_neg_integer()
  def sync_keys(user_id) when is_integer(user_id) do
    rpm = key_requests_per_minute(user_id)

    {n, _} =
      Repo.update_all(
        from(k in ApiKey,
          where: k.user_id == ^user_id and is_nil(k.revoked_at) and k.requests_per_minute != ^rpm
        ),
        set: [requests_per_minute: rpm, updated_at: now()]
      )

    n
  end

  # ---------------------------------------------------------------------------

  @doc "Rows by status and Stripe status, for `Release.plans_status/0`."
  def counts do
    Repo.all(
      from(s in PlanSubscription,
        group_by: [s.stripe_mode, s.status, s.stripe_status],
        select: {s.stripe_mode, s.status, s.stripe_status, count(s.id)}
      )
    )
  end

  @doc "How many of each event plans need the webhook has delivered, in one mode."
  def delivered_events(livemode) when is_boolean(livemode) do
    Repo.all(
      from(e in Bitblocks.Payments.StripeEvent,
        where: e.type in ^webhook_events() and e.livemode == ^livemode,
        group_by: e.type,
        select: {e.type, count(e.id)}
      )
    )
    |> Map.new()
  end

  @doc "The events plans need on the webhook endpoint."
  def webhook_events do
    ~w(checkout.session.completed checkout.session.expired customer.subscription.created
       customer.subscription.updated customer.subscription.deleted invoice.paid invoice.payment_failed)
  end

  @doc "A plain sentence for a refusal from `choose/3` or `portal_url/2`."
  def refusal_message(:not_signed_in), do: "Sign in with GitHub to choose a plan."
  def refusal_message(:not_configured), do: "Monthly plans aren't open yet."
  def refusal_message(:unknown_plan), do: "That plan isn't offered."

  def refusal_message(:already_subscribed),
    do: "You already have a plan. Change it from \"Manage billing\"."

  def refusal_message(:no_customer),
    do: "Stripe hasn't confirmed your subscription yet. Try again in a minute."

  def refusal_message(_), do: "Stripe couldn't open that just now. Try again shortly."

  defp id_of(id) when is_binary(id) and id != "", do: id
  defp id_of(%{"id" => id}), do: id_of(id)
  defp id_of(_), do: nil

  defp string_or(s, _default) when is_binary(s) and s != "", do: s
  defp string_or(_, default), do: default

  defp unix(n) when is_integer(n), do: DateTime.from_unix!(n)
  defp unix(_), do: nil

  defp update!(row, changes), do: row |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
