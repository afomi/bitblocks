defmodule Bitblocks.Payments.X402 do
  @moduledoc """
  x402 payments for the AI crawler 402, through x402_ex (docs/STRIPE.md).

  An AI crawler over its family's budget (`BitblocksWeb.Plugs.RateLimiter`)
  can pay for the one request it made: the 402 carries a `PAYMENT-REQUIRED`
  offer, and a retry with a `PAYMENT-SIGNATURE` header is verified and settled
  by the facilitator, claimed exactly once in `x402_payments`
  (`Bitblocks.Payments.X402Guard`), recorded in Stripe, and served.

  ## Configuration

  Off unless set (`config/runtime.exs`):

      config :bitblocks, Bitblocks.Payments.X402,
        enabled: true,                 # X402_ENABLED
        network: "eip155:84532",       # X402_NETWORK, Base Sepolia by default
        pay_to: "0x…",                 # X402_PAY_TO, our Stripe deposit address
        price_atomic: 10_000,          # X402_PRICE_ATOMIC, 0.01 USDC
        facilitator: "x402org",        # X402_FACILITATOR
        paid_per_ip_per_minute: 30,     # X402_PAID_PER_IP_PER_MINUTE
        paid_per_family_per_minute: 600 # X402_PAID_PER_FAMILY_PER_MINUTE

  `enabled: true` takes effect only with a `pay_to`, on a network whose USDC
  x402_ex knows (Base `eip155:8453`, Base Sepolia `eip155:84532`); otherwise
  `enabled?/0` is false and the crawler 402 is unchanged.

  The Stripe key is chosen by network: Base Sepolia records with
  `STRIPE_SANDBOX_SECRET_KEY`, Base mainnet with `STRIPE_SECRET_KEY`. Each is
  read from the environment when a payment is recorded, inside a 0-arity
  function, so it never sits in config, an argument list or a log.
  """

  require Logger

  alias Bitblocks.Payments.X402Guard

  @app "bitblocks"
  @sepolia "eip155:84532"
  @base "eip155:8453"
  @default_price_atomic 10_000
  @default_paid_per_ip 30
  @default_paid_per_family 600

  @stripe_key_env %{@sepolia => "STRIPE_SANDBOX_SECRET_KEY", @base => "STRIPE_SECRET_KEY"}

  @deposit_url "https://api.stripe.com/v1/crypto/deposit_addresses"
  # docs.stripe.com/payments/machine/x402 (read 2026-11-18): the live section
  # creates the deposit address with 2026-05-27.preview, the sandbox section
  # with 2026-07-29.preview.
  @deposit_version_live "2026-05-27.preview"
  @deposit_version_sandbox "2026-07-29.preview"

  @doc "The app name on every claim row, and in the x402 scope."
  def app, do: @app

  @doc """
  True when payments are switched on and can be taken: enabled, a deposit
  address set, and a network whose USDC x402_ex knows.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config(:enabled, false) == true and is_binary(pay_to()) and pay_to() != "" and
      match?({:ok, _}, X402.Scheme.ExactEvm.usdc(network()))
  end

  @doc """
  Why payments are off, or `:ok`. For the boot log and `Release.x402_status/0`.
  """
  @spec status() :: :ok | :disabled | :no_pay_to | :unknown_network
  def status do
    cond do
      config(:enabled, false) != true -> :disabled
      pay_to() in [nil, ""] -> :no_pay_to
      not match?({:ok, _}, X402.Scheme.ExactEvm.usdc(network())) -> :unknown_network
      true -> :ok
    end
  end

  @doc "The CAIP-2 network offered (default Base Sepolia, `eip155:84532`)."
  def network, do: config(:network, @sepolia)

  @doc "The deposit address every offer pays."
  def pay_to, do: config(:pay_to, nil)

  @doc "The price of one request over the budget, in USDC atomic units (10,000 = 0.01 USDC)."
  def price_atomic, do: config(:price_atomic, @default_price_atomic)

  @doc "The price in USDC, as text (\"0.01\")."
  def price_usdc do
    atomic = price_atomic()
    frac = atomic |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    # Two places for a whole number of cents (x402_ex records only those), six otherwise.
    frac = if String.ends_with?(frac, "0000"), do: binary_part(frac, 0, 2), else: frac
    "#{div(atomic, 1_000_000)}.#{frac}"
  end

  @doc "A human name for the network."
  def network_name(@sepolia), do: "Base Sepolia (testnet)"
  def network_name(@base), do: "Base"
  def network_name(other), do: other

  @doc "Paid attempts a minute from one IP (each costs a facilitator call)."
  def paid_per_ip_per_minute, do: config(:paid_per_ip_per_minute, @default_paid_per_ip)

  @doc "Paid attempts a minute from one crawler family, across its IPs."
  def paid_per_family_per_minute,
    do: config(:paid_per_family_per_minute, @default_paid_per_family)

  @doc """
  The offer for one request: the configured price, network and deposit
  address, for this exact URL (path and query), so a payment for one URL
  isn't spent on another.
  """
  @spec offer(Plug.Conn.t()) :: X402.Offer.t()
  def offer(%Plug.Conn{} = conn) do
    {:ok, usdc} = X402.Scheme.ExactEvm.usdc(network())

    X402.Offer.new!(%{
      amount: price_atomic(),
      network: network(),
      asset: usdc.asset,
      extra: usdc.extra,
      pay_to: pay_to(),
      resource: resource_url(conn),
      description: "One request over the AI crawler budget",
      max_timeout_seconds: 60
    })
  end

  defp resource_url(conn) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    BitblocksWeb.Endpoint.url() <> conn.request_path <> query
  end

  @doc """
  Runs `X402.handle/2` for this request with our offer, scope, facilitator,
  guard and Stripe recording.
  """
  @spec handle(Plug.Conn.t()) :: X402.result()
  def handle(%Plug.Conn{} = conn) do
    offer = offer(conn)

    X402.handle(conn,
      offer: offer,
      scope: [app: @app, pay_to: pay_to()],
      facilitator: facilitator(),
      replay_guard: {X402Guard, []},
      on_settled: &record_in_stripe/1
    )
  end

  @doc "The `PAYMENT-REQUIRED` header value for this request's offer."
  @spec challenge(Plug.Conn.t()) :: String.t()
  def challenge(conn),
    do: X402.Offer.challenge_header(offer(conn), "PAYMENT-SIGNATURE header is required")

  @doc false
  # on_settled: what X402.handle/2 gives it, recorded as a PaymentIntent.
  def record_in_stripe(settled) do
    X402.Stripe.record(stripe_secret(settled.offer.network), settled, stripe_opts())
  end

  @doc """
  Records settled payments that have no PaymentIntent yet (a Stripe outage
  during the request). Safe to repeat: Stripe's idempotency key is the
  transaction hash. Run every 10 minutes by `Bitblocks.Workers.X402ReconcileWorker`.

  Returns x402_ex's `{:ok, %{recorded: [...], failed: [...]}}`, or
  `{:ok, :disabled}` when payments are off and nothing was looked at.
  """
  @spec reconcile(keyword()) :: {:ok, map() | :disabled} | {:error, term()}
  def reconcile(opts \\ []) do
    if enabled?() or Keyword.get(opts, :force, false) do
      X402.Reconciler.record_unrecorded(
        {X402Guard, []},
        stripe_secret(network()),
        limit: Keyword.get(opts, :limit, 100),
        stripe_opts: stripe_opts()
      )
    else
      {:ok, :disabled}
    end
  end

  # The key for this network, read only when Stripe is called. Base Sepolia
  # is the sandbox; Base mainnet is live. x402_ex refuses a live key on
  # Sepolia and a test key on mainnet.
  defp stripe_secret(network) do
    env = Map.get(@stripe_key_env, network, "STRIPE_SANDBOX_SECRET_KEY")
    fn -> System.get_env(env) || "" end
  end

  @doc "The environment variable whose key records payments on `network`."
  def stripe_key_env(network \\ network()),
    do: Map.get(@stripe_key_env, network, "STRIPE_SANDBOX_SECRET_KEY")

  # Test seam only: req_options are refused by x402_ex unless config/test.exs
  # allows them.
  defp stripe_opts, do: config(:stripe_opts, [])

  defp facilitator do
    case config(:facilitator, "x402org") do
      "x402org" ->
        {X402.Facilitator.X402Org, config(:facilitator_opts, [])}

      {module, opts} when is_atom(module) ->
        {module, opts}

      other ->
        # Fail closed and loud: an unknown facilitator name would otherwise
        # take money nowhere. CDP (mainnet) is not usable in x402_ex v0.1.
        raise ArgumentError, "X402_FACILITATOR #{inspect(other)} is not supported; use x402org"
    end
  end

  # ---------------------------------------------------------------------------
  # The deposit address: created once, off the request path.

  @doc """
  Creates the Stripe crypto deposit address that `X402_PAY_TO` holds.

  Dry run by default: says which key and request it would use, and calls
  nothing. With `apply: true`, it sends

      POST https://api.stripe.com/v1/crypto/deposit_addresses
      Stripe-Version: 2026-07-29.preview (sandbox) | 2026-05-27.preview (live)
      network=base

  as docs.stripe.com/payments/machine/x402 shows, with the key for the
  configured `X402_NETWORK` (Base Sepolia: `STRIPE_SANDBOX_SECRET_KEY`), and
  returns `{:ok, address}`. It never returns or logs the key or Stripe's
  error messages.

  Options: `network:` (Stripe's network name, default `"base"`), `apply:`,
  `key_env:` (another environment variable to read the key from),
  `stripe_version:`.
  """
  @spec create_deposit_address(keyword()) ::
          {:dry_run, map()} | {:ok, String.t()} | {:error, term()}
  def create_deposit_address(opts \\ []) do
    stripe_network = Keyword.get(opts, :network, "base")
    key_env = Keyword.get(opts, :key_env, stripe_key_env())

    with {:ok, key} <- deposit_key(key_env) do
      version = Keyword.get(opts, :stripe_version, deposit_version(key))

      plan = %{
        url: @deposit_url,
        network: stripe_network,
        stripe_version: version,
        key_env: key_env,
        key_mode: key_mode(key)
      }

      if Keyword.get(opts, :apply, false) do
        post_deposit_address(key, stripe_network, version)
      else
        {:dry_run, plan}
      end
    end
  end

  defp deposit_key(env) do
    case System.get_env(env) do
      "sk_" <> _ = key -> {:ok, key}
      "rk_" <> _ = key -> {:ok, key}
      nil -> {:error, {:key_not_set, env}}
      _ -> {:error, {:key_malformed, env}}
    end
  end

  defp key_mode(key) do
    if String.starts_with?(key, ["sk_live_", "rk_live_"]), do: :live, else: :sandbox
  end

  defp deposit_version(key) do
    if key_mode(key) == :live, do: @deposit_version_live, else: @deposit_version_sandbox
  end

  defp post_deposit_address(key, stripe_network, version) do
    req =
      Req.new(
        method: :post,
        url: @deposit_url,
        headers: [{"authorization", "Bearer " <> key}, {"stripe-version", version}],
        form: [network: stripe_network],
        retry: false,
        redirect: false,
        receive_timeout: 15_000
      )
      |> Req.merge(deposit_req_options())

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        deposit_address(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:stripe_error, status, stripe_error_code(body)}}

      {:error, %{__struct__: mod}} ->
        {:error, {:unavailable, mod}}
    end
  end

  # The test seam (a Req.Test plug), honoured only where x402_ex's own is:
  # config/test.exs. A plug anywhere else could stand in for Stripe.
  defp deposit_req_options do
    if Application.get_env(:x402_ex, :allow_req_options, false),
      do: config(:deposit_req_options, []),
      else: []
  end

  # UNCONFIRMED: Stripe's docs say "Store the returned address" without
  # showing the response body. We take a top-level "address"; anything else
  # is reported by its top-level keys only, for a person to read.
  defp deposit_address(%{"address" => "0x" <> hex = address}) when byte_size(hex) == 40,
    do: {:ok, address}

  defp deposit_address(%{} = body), do: {:error, {:unexpected_response, Map.keys(body)}}
  defp deposit_address(_), do: {:error, {:unexpected_response, []}}

  defp stripe_error_code(%{"error" => %{} = e}), do: {e["type"], e["code"]}
  defp stripe_error_code(_), do: {nil, nil}

  defp config(key, default) do
    :bitblocks
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
