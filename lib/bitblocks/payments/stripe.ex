defmodule Bitblocks.Payments.Stripe do
  @moduledoc """
  Stripe Checkout, the customer portal and signed webhooks, for paid bulk
  downloads (https://github.com/afomi/bitblocks/issues/111) and monthly
  plans (https://github.com/afomi/bitblocks/issues/112), docs/STRIPE.md.

  Requests go through x402_ex's hardened client (`X402.HTTPClient`): no
  retries, no redirects, a bounded body and deadline, and its test seam
  (`req_options: [plug: {Req.Test, name}]`), which x402_ex refuses unless
  `config :x402_ex, allow_req_options: true` (config/test.exs only). So one
  HTTP client and one way of stubbing Stripe serve both payment lines.

  ## Mode and keys

  `config :bitblocks, #{inspect(__MODULE__)}, mode: "sandbox" | "live"`
  (`DOWNLOADS_CHECKOUT_MODE`, default `"sandbox"`), and for each mode two
  environment variables, read only when needed and never held in config:

  | Mode | Secret key | Webhook signing secret |
  | --- | --- | --- |
  | sandbox | `STRIPE_SANDBOX_SECRET_KEY` | `STRIPE_SANDBOX_WEBHOOK_SECRET` |
  | live | `STRIPE_SECRET_KEY` | `STRIPE_WEBHOOK_SECRET` |

  `configured?/0` is true only with both set, the key of the mode's kind
  (`sk_test_`/`rk_test_` for sandbox, `sk_live_`/`rk_live_` for live) and a
  `whsec_` secret. Until then Checkout is dormant: no Pay button, no session.

  Keys and secrets never appear in a return value, a log line or an error;
  Stripe's error messages are dropped too (they can echo part of a key).
  """

  require Logger

  alias X402.HTTPClient

  @checkout_url "https://api.stripe.com/v1/checkout/sessions"
  @portal_url "https://api.stripe.com/v1/billing_portal/sessions"
  # Pinned so a dashboard default change can't move the shapes we read.
  @default_version "2024-06-20"
  @tolerance_seconds 300

  @envs %{
    "sandbox" => %{key: "STRIPE_SANDBOX_SECRET_KEY", webhook: "STRIPE_SANDBOX_WEBHOOK_SECRET"},
    "live" => %{key: "STRIPE_SECRET_KEY", webhook: "STRIPE_WEBHOOK_SECRET"}
  }

  @doc "\"sandbox\" (Stripe test mode, the default) or \"live\"."
  @spec mode() :: String.t()
  def mode do
    case config(:mode, "sandbox") do
      "live" -> "live"
      _ -> "sandbox"
    end
  end

  @doc "Whether this mode is Stripe's live mode, as events report it (`livemode`)."
  def livemode?, do: mode() == "live"

  @doc "The environment variable holding the secret key for `mode`."
  def key_env(mode \\ mode()), do: @envs[mode].key

  @doc "The environment variable holding the webhook signing secret for `mode`."
  def webhook_secret_env(mode \\ mode()), do: @envs[mode].webhook

  @doc """
  `:ok`, or why Checkout is dormant: `:no_key`, `:key_mode_mismatch`,
  `:no_webhook_secret`, `:webhook_secret_malformed`.
  """
  @spec status() :: :ok | atom()
  def status do
    key = System.get_env(key_env())
    secret = System.get_env(webhook_secret_env())

    cond do
      key in [nil, ""] -> :no_key
      not key_fits_mode?(key, mode()) -> :key_mode_mismatch
      secret in [nil, ""] -> :no_webhook_secret
      not String.starts_with?(secret, "whsec_") -> :webhook_secret_malformed
      true -> :ok
    end
  end

  @doc "True when Checkout can take a payment and its webhook can be verified."
  @spec configured?() :: boolean()
  def configured?, do: status() == :ok

  defp key_fits_mode?(key, "live"), do: String.starts_with?(key, ["sk_live_", "rk_live_"])
  defp key_fits_mode?(key, _), do: String.starts_with?(key, ["sk_test_", "rk_test_"])

  @doc """
  Creates a Checkout session: one card payment of `amount_cents` USD for one
  item named `name`. `idempotency_key` is the purchase id, so asking twice
  returns the same session. Returns `{:ok, %{id: "cs_...", url: "https://..."}}`.

  `params`: `:amount_cents`, `:name`, `:description`, `:success_url`,
  `:cancel_url`, `:client_reference_id`, `:metadata` (a map), `:customer_email`.
  """
  @spec create_checkout_session(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_checkout_session(params, idempotency_key) when is_binary(idempotency_key) do
    with :ok <- status_ok(),
         {:ok, key} <- secret_key() do
      post(key, @checkout_url, checkout_form(params), idempotency_key, &checkout_response/1)
    end
  end

  @doc """
  Creates a Checkout session in subscription mode for one configured Stripe
  Price (`price_id`, billed monthly), for monthly plans
  (https://github.com/afomi/bitblocks/issues/112). The amount is that Price's,
  set in Stripe; nothing from the browser reaches it. `idempotency_key` is the
  plan subscription's id. Returns `{:ok, %{id: "cs_...", url: "https://..."}}`.

  `params`: `:price_id`, `:success_url`, `:cancel_url`, `:client_reference_id`,
  `:metadata` (a map, set on both the session and the subscription), and
  `:customer` (a `cus_` id we already hold for this user) when there is one.
  """
  @spec create_subscription_checkout(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_subscription_checkout(params, idempotency_key) when is_binary(idempotency_key) do
    with :ok <- status_ok(),
         {:ok, key} <- secret_key() do
      post(
        key,
        @checkout_url,
        subscription_checkout_form(params),
        idempotency_key,
        &checkout_response/1
      )
    end
  end

  @doc "The subscription Checkout form body, as ordered pairs (exposed for tests and review)."
  @spec subscription_checkout_form(map()) :: [{String.t(), String.t()}]
  def subscription_checkout_form(params) do
    metadata = Map.get(params, :metadata, %{})

    customer =
      case params[:customer] do
        "cus_" <> _ = customer -> [{"customer", customer}]
        _ -> []
      end

    [
      {"mode", "subscription"},
      {"line_items[0][price]", params.price_id},
      {"line_items[0][quantity]", "1"},
      {"success_url", params.success_url},
      {"cancel_url", params.cancel_url},
      {"client_reference_id", params.client_reference_id}
    ] ++
      customer ++
      for({k, v} <- metadata, do: {"metadata[#{k}]", to_string(v)}) ++
      for {k, v} <- metadata, do: {"subscription_data[metadata][#{k}]", to_string(v)}
  end

  @doc """
  Creates a customer portal session for `customer` (a `cus_` id), returning to
  `return_url`: where a subscriber updates the card, changes plan or cancels.
  Needs the portal set up in the Dashboard and the key's
  **Customer portal: Write**. Returns `{:ok, %{id: "bps_...", url: "https://..."}}`.
  """
  @spec create_portal_session(String.t() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def create_portal_session("cus_" <> _ = customer, return_url) when is_binary(return_url) do
    with :ok <- status_ok(),
         {:ok, key} <- secret_key() do
      # A portal session is short-lived and harmless to make twice, so each
      # click gets its own idempotency key.
      idempotency_key = "portal:" <> Base.url_encode64(:crypto.strong_rand_bytes(12))

      post(
        key,
        @portal_url,
        [{"customer", customer}, {"return_url", return_url}],
        idempotency_key,
        &portal_response/1
      )
    end
  end

  def create_portal_session(_customer, _return_url), do: {:error, :no_customer}

  defp checkout_response(%{"id" => "cs_" <> _ = id, "url" => url}) when is_binary(url) do
    # The browser is sent here, so only Stripe's own Checkout host.
    if stripe_checkout_url?(url),
      do: {:ok, %{id: id, url: url}},
      else: {:error, :invalid_response}
  end

  defp checkout_response(_), do: {:error, :invalid_response}

  defp portal_response(%{"id" => "bps_" <> _ = id, "url" => url}) when is_binary(url) do
    if stripe_host_url?(url, "billing.stripe.com"),
      do: {:ok, %{id: id, url: url}},
      else: {:error, :invalid_response}
  end

  defp portal_response(_), do: {:error, :invalid_response}

  defp status_ok do
    case status() do
      :ok -> :ok
      other -> {:error, {:not_configured, other}}
    end
  end

  @doc "The Checkout form body, as ordered pairs (exposed for tests and review)."
  @spec checkout_form(map()) :: [{String.t(), String.t()}]
  def checkout_form(params) do
    item = "line_items[0]"

    [
      {"mode", "payment"},
      {"payment_method_types[0]", "card"},
      {"#{item}[quantity]", "1"},
      {"#{item}[price_data][currency]", "usd"},
      {"#{item}[price_data][unit_amount]", Integer.to_string(params.amount_cents)},
      {"#{item}[price_data][product_data][name]", params.name},
      {"success_url", params.success_url},
      {"cancel_url", params.cancel_url},
      {"client_reference_id", params.client_reference_id}
    ] ++
      optional("#{item}[price_data][product_data][description]", params[:description]) ++
      optional("customer_email", params[:customer_email]) ++
      for {k, v} <- Map.get(params, :metadata, %{}), do: {"metadata[#{k}]", to_string(v)}
  end

  defp optional(_k, nil), do: []
  defp optional(_k, ""), do: []
  defp optional(k, v), do: [{k, v}]

  defp secret_key do
    case System.get_env(key_env()) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, {:not_configured, :no_key}}
    end
  end

  defp post(key, url, form, idempotency_key, parse) do
    timeout = 10_000

    req = [
      method: :post,
      url: url,
      headers: [
        {"authorization", "Bearer " <> key},
        {"stripe-version", config(:stripe_version, @default_version)},
        {"idempotency-key", idempotency_key},
        {"content-type", "application/x-www-form-urlencoded"}
      ],
      body: URI.encode_query(form, :www_form),
      connect_options: [timeout: 2_000],
      receive_timeout: timeout
    ]

    case HTTPClient.request(req, deadline_ms: timeout, req_options: config(:req_options, [])) do
      {:ok, status, body} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{} = decoded} -> parse.(decoded)
          _ -> {:error, :invalid_response}
        end

      {:ok, status, body} ->
        {type, code} = stripe_error(body)
        Logger.warning("Stripe checkout refused status=#{status} type=#{type} code=#{code}")
        {:error, {:stripe_error, status, type, code}}

      {:error, reason} ->
        Logger.warning("Stripe checkout unavailable: #{inspect(reason)}")
        {:error, :stripe_unavailable}
    end
  end

  @doc "True for an https URL on Stripe's Checkout host."
  def stripe_checkout_url?(url), do: stripe_host_url?(url, "checkout.stripe.com")

  defp stripe_host_url?(url, host) when is_binary(url) do
    match?(%URI{scheme: "https", host: ^host, userinfo: nil}, URI.parse(url))
  end

  defp stripe_host_url?(_, _), do: false

  defp stripe_error(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{} = e}} -> {safe_code(e["type"]), safe_code(e["code"])}
      _ -> {nil, nil}
    end
  end

  defp safe_code(v) when is_binary(v) do
    if Regex.match?(~r/\A[a-z0-9_]{1,64}\z/, v), do: v, else: nil
  end

  defp safe_code(_), do: nil

  # ---------------------------------------------------------------------------
  # Webhooks

  @doc """
  Verifies a webhook delivery's `Stripe-Signature` header against the raw
  body, with the mode's signing secret, and decodes it.

  The header is `t=<unix seconds>,v1=<hex>[,v1=<hex>...]`; a `v1` is the
  HMAC-SHA256 of `"<t>.<raw body>"` under the secret. A delivery passes when
  any `v1` matches (compared in constant time) and `t` is within
  #{@tolerance_seconds} seconds of now, so an old delivery can't be replayed
  later. Returns `{:ok, event}` or `{:error, reason}`:
  `:not_configured`, `:no_signature`, `:bad_signature`, `:timestamp_outside_tolerance`,
  `:invalid_payload`.
  """
  @spec verify_webhook(binary(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, atom()}
  def verify_webhook(raw_body, header, opts \\ []) do
    secret = Keyword.get_lazy(opts, :secret, fn -> System.get_env(webhook_secret_env()) end)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    tolerance = Keyword.get(opts, :tolerance, @tolerance_seconds)

    with :ok <- secret_present(secret),
         {:ok, t, signatures} <- parse_signature(header),
         :ok <- within_tolerance(t, now, tolerance),
         :ok <- signature_matches(secret, t, raw_body, signatures),
         {:ok, %{"id" => "evt_" <> _, "type" => type} = event} when is_binary(type) <-
           Jason.decode(raw_body) do
      {:ok, event}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_payload}
    end
  end

  @doc """
  The `Stripe-Signature` header for `raw_body` at `t`, as Stripe signs it.
  For tests (and for checking a captured delivery by hand).
  """
  @spec sign(binary(), String.t(), integer()) :: String.t()
  def sign(raw_body, secret, t) do
    "t=#{t},v1=#{hmac(secret, t, raw_body)}"
  end

  defp secret_present(s) when is_binary(s) and s != "", do: :ok
  defp secret_present(_), do: {:error, :not_configured}

  defp parse_signature(header) when is_binary(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    t =
      Enum.find_value(pairs, fn
        ["t", v] ->
          case Integer.parse(v) do
            {n, ""} -> n
            _ -> nil
          end

        _ ->
          nil
      end)

    signatures = for ["v1", v] <- pairs, do: String.downcase(v)

    if is_integer(t) and signatures != [],
      do: {:ok, t, signatures},
      else: {:error, :no_signature}
  end

  defp parse_signature(_), do: {:error, :no_signature}

  defp within_tolerance(t, now, tolerance) do
    if abs(now - t) <= tolerance, do: :ok, else: {:error, :timestamp_outside_tolerance}
  end

  defp signature_matches(secret, t, raw_body, signatures) do
    expected = hmac(secret, t, raw_body)

    if Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)),
      do: :ok,
      else: {:error, :bad_signature}
  end

  defp hmac(secret, t, raw_body) do
    :crypto.mac(:hmac, :sha256, secret, "#{t}." <> raw_body) |> Base.encode16(case: :lower)
  end

  defp config(key, default) do
    :bitblocks |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
