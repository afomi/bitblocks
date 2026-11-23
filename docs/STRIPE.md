# Stripe

Bitblocks uses Stripe for two things:

- Recording x402 payments, through [x402_ex](https://github.com/afomi/x402_ex).
  A caller past a shared budget (an AI crawler family's, or the one everyone without a key shares) gets a 402 with a price; it pays in USDC, and each settled payment is recorded in Stripe as a machine payment.
  Your steps: [Turning x402 on](#turning-x402-on).
  The plan is under "Paid crawler access (x402)" in [PLAN.md](../PLAN.md).
- Selling bulk downloads of a block range with Stripe Checkout, at the published $1.00 per GiB (https://github.com/afomi/bitblocks/issues/111).
  It is built and dormant until the keys below are set: [Bulk downloads: Checkout](#bulk-downloads-checkout).
- Monthly plans, a Stripe subscription that raises a user's key limit without changing the key (https://github.com/afomi/bitblocks/issues/112).
  It is built and dormant until plans are configured: [Monthly plans](#monthly-plans).

All of them go through one HTTP client, x402_ex's `X402.HTTPClient`, and tests stub Stripe the same way (`Req.Test`), so no test ever calls Stripe.

Bitblocks has its own Stripe account, separate from jurisdictional's.
This repo is public: never put the account id, keys, draft prices or customer details in it.

## Rules for keys

- Never paste a key into a Claude session, an issue, a commit or a chat.
  You set every key yourself, from your own terminal.
- A test key starts `sk_test_` or `rk_test_`, and a live key starts `sk_live_` or `rk_live_`.
  x402_ex refuses a test key on Base mainnet and a live key on Base Sepolia, so a mix-up fails closed.
- Prefer a restricted key (`rk_…`) to the full secret key (`sk_…`).
  It gives bitblocks only what it needs, and can be rolled on its own.

## 1. Make the test key

1. Sign in at https://dashboard.stripe.com, and check that the account name at the top left says **Bitblocks**.
2. Click the account name, choose **Sandboxes**, and open the bitblocks sandbox, or create one named `bitblocks-x402`.
   A banner across the top shows you're in a sandbox; don't go on without it.
3. Open **Developers → API keys** (https://dashboard.stripe.com/apikeys), then **Create restricted key**.
   If Stripe asks how you'll use it, choose the option for your own integration.
4. Name it `bitblocks-x402-sandbox`.
5. Under permissions, set **PaymentIntents** to **Write**, and leave everything else at **None**.
   If the sandbox run is refused for a missing permission, add only the one Stripe names (**⋯ → Edit key**), and note it here.
6. Click **Create key**, then copy the key.
   It must start `rk_test_`; a key starting `rk_live_` was made in live mode, so delete it and go back to step 2.
   A sandbox key can be revealed again later; a live key is shown only once.

The key's own request log is under **⋯ → View request logs** next to it, which is where a refused call shows up.

## 2. Set it

The key goes into the bitblocks secret in AWS Secrets Manager (`bitblocks/prod`), under its own name, so it never sits beside a live key by accident.

In your own terminal, from your checkout of the infra repo:

```bash
pbpaste | aws-vault exec default -- ./scripts/app-secret-set.sh bitblocks STRIPE_SANDBOX_SECRET_KEY --stdin
```

Or, for a hidden prompt you paste into:

```bash
aws-vault exec default -- ./scripts/app-secret-set.sh bitblocks STRIPE_SANDBOX_SECRET_KEY
```

The script prints no value, and confirms the key is set by reading it back.
Then clear the clipboard (copy anything else).

The next deploy writes the secret to `/opt/bitblocks.env` on each node (`.github/scripts/deploy.sh`).
Until a deploy runs, the running app doesn't see the new key.

To check it's set without seeing it, tell the session "STRIPE_SANDBOX_SECRET_KEY is set".
It can then confirm the name is present, never the value.

## 3. What happens with it

- The sandbox run pays the configured price in test USDC on Base Sepolia, through the public test facilitator `https://x402.org/facilitator`.
  The test USDC comes from https://faucet.circle.com, and no real money moves.
- Each paid retry should create one PaymentIntent in the Stripe test dashboard, under **Payments**, idempotent on the on-chain transaction hash.
- A replay of the same payment should be refused, and create nothing.

## Turning x402 on

x402 lets a caller past a shared budget (an AI crawler family's, or the one every caller with no key and no session shares) pay for the one request, with no key and no account.
It is built, tested end to end against a stubbed facilitator (`test/bitblocks_web/plugs/rate_limiter/x402_test.exs`), and off until the steps below.
You set every value yourself; a session never asks for one and never sees one.

At any point, from a node:

```bash
bin/bitblocks rpc 'Bitblocks.Release.x402_status()'
```

It says `x402: on` or `off`, the network, price, deposit address, facilitator, which Stripe key variable it reads and whether it is set, how many payments have settled and how many aren't in Stripe yet, and under `missing:` each thing still in the way, naming the variable to set.
It never prints a key.

### 1. The deposit address

Every offer pays one deposit address, bitblocks' own, created once in Stripe and never shared with another app (x402_ex's rule: one deposit address per app).
It needs `STRIPE_SANDBOX_SECRET_KEY` set and deployed first (steps 1 and 2 above).

```bash
# Dry run: names the key variable and the request, and calls nothing
bin/bitblocks rpc 'Bitblocks.Release.x402_create_deposit_address(network: "base")'

# Creates it, and prints only the address
bin/bitblocks rpc 'Bitblocks.Release.x402_create_deposit_address(network: "base", apply: true)'
```

It sends `POST /v1/crypto/deposit_addresses` with `network=base`, as Stripe's x402 guide shows (https://docs.stripe.com/payments/machine/x402), with the key for `X402_NETWORK`: `STRIPE_SANDBOX_SECRET_KEY` on Base Sepolia, the default.
The `Stripe-Version` follows the guide: `2026-07-29.preview` with a sandbox key, `2026-05-27.preview` with a live one; `stripe_version:` overrides it.
If Stripe refuses it, the result names the status and Stripe's error type and code, never the key or Stripe's message.

Three things here are not yet confirmed against a real call:
- where the address sits in Stripe's response (the guide doesn't show it; we read a top-level `address`, and otherwise report only the response's top-level keys);
- which restricted-key permission the call needs beyond **PaymentIntents: Write** (add only what Stripe names, and note it here);
- whether a sandbox address on `network=base` takes Base Sepolia payments, as the guide's sandbox section implies.

The address goes only in the secret, never in this repo, an issue or a commit.

### 2. Set `X402_PAY_TO` and `X402_ENABLED`

In your own terminal, from your checkout of the infra repo, each at a hidden prompt you paste into:

```bash
aws-vault exec default -- ./scripts/app-secret-set.sh bitblocks X402_PAY_TO
aws-vault exec default -- ./scripts/app-secret-set.sh bitblocks X402_ENABLED
```

`X402_PAY_TO` is the address step 1 printed, and `X402_ENABLED` is `true`.
The script prints no value, and confirms each is set by reading it back.
Leave `X402_NETWORK` unset for the testnet run; it defaults to Base Sepolia.

Then run the deploy workflow by hand, so each node reads the secret:

```bash
gh workflow run "Deploy to AWS" --ref develop
```

Once it finishes, `Release.x402_status()` should say `x402: on` and `missing: nothing`.
If `X402_ENABLED` is `true` without what it needs, the app logs a warning at boot and stays off, and `missing:` says why.

### 3. A test payment on testnet

No real money moves: Base Sepolia, test USDC, and the public test facilitator `https://x402.org/facilitator`.

1. Make a test wallet with an x402 client, such as Stripe's `purl` from Stripe's machine payments docs (https://docs.stripe.com/payments/machine), and fund it with Base Sepolia USDC from https://faucet.circle.com.
2. Get past a budget on purpose.
   An AI crawler's user agent has the smallest one, so the eleventh request in a minute gets the 402:

   ```bash
   for i in $(seq 1 11); do
     curl -s -o /dev/null -w '%{http_code}\n' -A 'GPTBot/1.2' https://bitblocks.app/about
   done
   curl -s -D - -o /dev/null -A 'GPTBot/1.2' https://bitblocks.app/about | grep -i '^payment-required'
   ```

   The last line shows the `PAYMENT-REQUIRED` header: base64 JSON with the price, the USDC asset, `eip155:84532` and our deposit address.
3. With the x402 client, send the same request with the same user agent (most clients take an extra header), so it is still over the budget.
   It signs the offer, retries with `PAYMENT-SIGNATURE`, and gets the page with 200 and a `PAYMENT-RESPONSE` header naming the transaction.
4. Check it landed:

   ```bash
   bin/bitblocks rpc 'Bitblocks.Release.x402_status()'     # payments: 1 settled, 0 not yet in Stripe
   bin/bitblocks rpc 'Bitblocks.Release.x402_reconcile()'  # x402 reconcile: 0 recorded, 0 failed
   ```

   In the Stripe sandbox, **Payments** shows one PaymentIntent, idempotent on the on-chain transaction hash.
   If `x402_status()` says one is not yet in Stripe, `x402_reconcile()` records it (the `X402ReconcileWorker` cron does the same every 10 minutes); if it then reports one failed, the key's request log in Stripe names why.
5. Send the client's same signed payment again: it gets the 402 with a fresh offer, and nothing settles twice.

Paid requests are rows in `x402_payments`: an `auth:` row per claimed authorization, and a `tx:` row per settled transaction with its PaymentIntent.

### 4. Live mode

Live mode waits on your go, after the testnet run.
It needs:

- Stripe's approval for **Stablecoins and Crypto** (Dashboard → **Settings → Payment methods**); it shows Pending until Stripe approves it.
- A live restricted key with **PaymentIntents: Write**, set as `STRIPE_SECRET_KEY` the same way as the sandbox key.
- Coinbase Developer Platform (CDP) keys for the mainnet facilitator, set the same way.
  x402_ex v0.1 can't sign CDP requests yet (`X402.Facilitator.CDP`), so this also waits on an x402_ex release that can; until then a mainnet payment fails closed, and `x402_status()` says so.
- A live deposit address: step 1 again with `X402_NETWORK=eip155:8453` and the live key, then step 2 with the new address.
- The price, which you set: `X402_PRICE_ATOMIC`, in USDC atomic units (a millionth of a USDC each).
- Then `X402_NETWORK=eip155:8453` and a deploy, and `x402_status()` saying `missing: nothing`.

Then ask infra to lift the ALB rule for Meta's crawler, so it reaches the in-app offer.

### The settings

All in the bitblocks secret (`config/runtime.exs`), and off unless set:

| Variable | Default | What it does |
| --- | --- | --- |
| `X402_ENABLED` | `false` | `true` offers payment on the 402; it takes effect only with `X402_PAY_TO` set |
| `X402_PAY_TO` | none | the deposit address every offer pays |
| `X402_NETWORK` | `eip155:84532` | Base Sepolia; `eip155:8453` is Base mainnet |
| `X402_PRICE_ATOMIC` | set by Ryan | the price of one request, in USDC atomic units; `x402_status()` shows it |
| `X402_FACILITATOR` | `x402org` | the public test facilitator; the only one x402_ex v0.1 can use (mainnet's CDP fails closed) |
| `X402_PAID_PER_IP_PER_MINUTE` | `30` | paid attempts a minute from one IP, each a facilitator call |
| `X402_PAID_SITE_PER_MINUTE` | `600` | paid attempts a minute site-wide, from every caller together |
| `X402_PAID_PER_FAMILY_PER_MINUTE` | deprecated | read as `X402_PAID_SITE_PER_MINUTE` only when that is unset; drop it from the secret |
| `STRIPE_SANDBOX_SECRET_KEY` | none | records payments on Base Sepolia |
| `STRIPE_SECRET_KEY` | none | records payments on Base mainnet |

The Stripe key is chosen by network, and read only when a payment is recorded; x402_ex refuses a live key on Base Sepolia and a test key on Base mainnet.

## Bulk downloads: Checkout

A signed-in buyer quotes a block range on `/pricing#downloads`, clicks "Pay", and pays once by card on Stripe Checkout.
Stripe's signed `checkout.session.completed` webhook marks the purchase paid; the redirect back to `/downloads/<id>` alone opens nothing.
Then each file's sha256 is computed once from the tx store, and the page gives the manifest, signed links (S3 presigned, 15 minutes, re-issued free for 30 days) and a script that downloads, checks and resumes.
The code is `Bitblocks.Payments.Stripe` (Checkout and webhook signatures), `Bitblocks.Downloads.Purchases` (the purchase's life), `BitblocksWeb.StripeWebhookController` and `BitblocksWeb.DownloadLive`.

### What it needs

| Variable | Mode | What it is |
| --- | --- | --- |
| `DOWNLOADS_CHECKOUT_MODE` | | `sandbox` (the default, Stripe test mode) or `live` |
| `STRIPE_SANDBOX_SECRET_KEY` | sandbox | the sandbox key x402 already uses, with **Checkout Sessions: Write** added |
| `STRIPE_SANDBOX_WEBHOOK_SECRET` | sandbox | the sandbox webhook endpoint's signing secret, `whsec_…` |
| `STRIPE_SECRET_KEY` | live | the live key, with **Checkout Sessions: Write** |
| `STRIPE_WEBHOOK_SECRET` | live | the live webhook endpoint's signing secret, `whsec_…` |

With the mode's key or webhook secret missing, Checkout is dormant: no "Pay" button, the quote keeps "Contact us", and `POST /webhooks/stripe` answers 503.
A live key in sandbox mode, or a test key in live mode, is refused the same way.
In sandbox mode only an admin sees "Pay", so nobody buys real files with a test card.

```bash
bin/bitblocks rpc 'Bitblocks.Release.downloads_checkout_status()'
```

It prints the mode, each variable's name and whether it is set (never a value), and the purchases by status.

### Your steps, test mode first

1. In the Stripe Dashboard, open the bitblocks sandbox (the banner across the top says you're in a sandbox).
2. **Developers → API keys**: on the sandbox restricted key (`bitblocks-x402-sandbox`), choose **⋯ → Edit key**, set **Checkout Sessions** to **Write**, and save.
   The key's value doesn't change, so `STRIPE_SANDBOX_SECRET_KEY` stays as it is.
   If a payment is refused for a missing permission, the key's request log names it; add only that one, and note it here.
3. **Developers → Webhooks → Add endpoint** (in the sandbox):
   - Endpoint URL: `https://bitblocks.app/webhooks/stripe`
   - Events: `checkout.session.completed`, `checkout.session.expired`, `charge.refunded`
   - Then open the endpoint and reveal its **Signing secret** (`whsec_…`).
4. Set it, in your own terminal, from your checkout of the infra repo (a hidden prompt you paste into):

   ```bash
   aws-vault exec default -- ./scripts/app-secret-set.sh bitblocks STRIPE_SANDBOX_WEBHOOK_SECRET
   ```

5. Deploy (or run the deploy workflow by hand), so the nodes read it, then check `Release.downloads_checkout_status()` says `configured`.
6. Signed in as an admin, quote a small range on `/pricing#downloads`, click "Pay", and pay with Stripe's test card `4242 4242 4242 4242` (any future date, any CVC).
   You land on `/downloads/<id>`, which says "Waiting for payment confirmation" and turns to "Paid" when the webhook arrives.
   The payment shows under **Payments** in the sandbox, and the webhook delivery under the endpoint.
7. Refund it in the Dashboard: the page turns to "Refunded" and its links close.

Stripe's smallest card payment is $0.50, so a range under that is refused before Checkout.
A purchase is one Checkout session: the session's idempotency key is the purchase id, and a second "Pay" on the same quote within a day reopens the same session.
Every event is recorded in `stripe_events` by its id before it changes anything, so a replay or a second delivery does nothing.
Any refund, whole or part, closes the links.

### Live, later

Set `DOWNLOADS_CHECKOUT_MODE=live`, give the live restricted key **Checkout Sessions: Write** (`STRIPE_SECRET_KEY`), add the same webhook endpoint in live mode, and set its secret as `STRIPE_WEBHOOK_SECRET`.
In live mode every signed-in user sees "Pay".

## Monthly plans

A signed-in user picks a plan on `/pricing#plans`, clicks "Choose", and subscribes on Stripe Checkout.
Stripe's signed webhooks, never the redirect, move their key to the plan's rate limit: the same key, a higher `requests_per_minute`, from their next request on this node and within a minute on the others.
"Your plan" on `/pricing#plan` shows the plan, its status and renewal date, this period's use against the allowance (from `Bitblocks.Usage`), and "Manage billing", which opens Stripe's customer portal.
The code is `Bitblocks.Billing` (plans and the subscription's life), `Bitblocks.Payments.StripeEvents` (the one event dedupe, for downloads and plans), `Bitblocks.Payments.Stripe` (Checkout, the portal, signatures) and `BitblocksWeb.PlanComponents`.

It uses the same key, the same webhook endpoint and the same `stripe_events` table as bulk downloads; nothing is added beside them.

### How it decides

- A plan is entitled while Stripe says the subscription is `active`, `trialing` or `past_due`.
  A failed payment keeps the plan's limit through Stripe's retries; when Stripe gives up (`unpaid` or `canceled`) or the subscription ends, the key goes back to the trial's 60 a minute.
  What Stripe does after the last retry is set in the Dashboard (**Settings → Billing → Subscriptions and emails → Manage failed payments**); either cancelling or marking unpaid ends the plan here.
- Events are handled once by their id, and an event older than the newest one applied to that subscription (by its `created`) changes nothing, so they can arrive in any order.
- Every key the user owns follows the plan, and a key they make later starts at the plan's limit.
- The allowance is shown, not enforced: at 100% the key keeps the plan's rate and "Your plan" says so; nothing is billed as overage.
- A plan switched in the customer portal moves the subscription to the plan with that Price, and its limits.
- Each subscription keeps a copy of its plan's limits as chosen, so editing the plans' config never changes a subscriber's limit by itself.
- In sandbox mode only an admin sees the plans, so no test price shows to the public.

### Plans are config, never in this repo

Plans live in the bitblocks secret as `BILLING_PLANS`, a JSON array, one object per plan:

| Field | What it is |
| --- | --- |
| `id` | a short slug, `a-z`, `0-9`, `_` or `-` |
| `name` | what `/pricing` calls it |
| `price_cents` | the monthly price `/pricing` shows, in US cents |
| `stripe_price_id` | the Stripe Price Checkout charges, `price_…`: monthly, recurring, the same amount |
| `requests_per_minute` | the key's rate limit on the plan, up to 100,000 |
| `monthly_requests` | the monthly allowance of API requests |
| `monthly_gib` | the monthly allowance of data sent, in GiB |

Its shape, with placeholders where the decided numbers go:

```json
[
  {"id": "tier_1", "name": "<name>", "price_cents": <cents>, "stripe_price_id": "price_<id>",
   "requests_per_minute": <rpm>, "monthly_requests": <requests>, "monthly_gib": <gib>}
]
```

Checkout charges the Stripe Price, and the page shows `price_cents`, so set both to the same amount.
Each subscription event that carries the Price's amount is checked against `price_cents`, and a mismatch is logged as an error.
One plan that doesn't parse turns every plan off, and `plans_status()` names it.
With `BILLING_PLANS` unset, `/pricing` reads as it did: no plans section and no "Choose".

```bash
bin/bitblocks rpc 'Bitblocks.Release.plans_status()'
```

It prints the mode, each key and secret's name and whether it is set (never a value), each plan with its limits, which of the needed events the webhook has delivered so far, and the subscriptions by status.

### Your steps, test mode first

1. In the sandbox, **Product catalog → Add product**, once per plan: a name, and a **Recurring**, **Monthly** price in USD.
   Copy each price's id (`price_…`).
2. **Developers → API keys**: on the sandbox restricted key, choose **⋯ → Edit key**, set **Checkout Sessions** to **Write** (if downloads haven't already) and **Customer portal** to **Write**, and save.
   The key's value doesn't change.
   If a call is refused for a missing permission, the key's request log names it; add only that one, and note it here.
3. **Settings → Billing → Customer portal**: turn on cancelling and updating the payment method.
   To let subscribers switch plans there, add the plans' products under **Subscriptions → Customers can switch plans**.
4. **Developers → Webhooks**: on the `https://bitblocks.app/webhooks/stripe` endpoint from [bulk downloads](#your-steps-test-mode-first) (add it as step 3 there says if it isn't there yet), choose **Edit destination** and add these events to the ones it has:
   `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid`, `invoice.payment_failed`.
   It already has `checkout.session.completed` and `checkout.session.expired`; one endpoint serves both, and adding events doesn't change its signing secret.
5. Write the plans' JSON in a local file outside any repo, with the price ids from step 1, then set it from your own terminal (a hidden prompt you paste into):

   ```bash
   aws-vault exec default -- ./scripts/app-secret-set.sh bitblocks BILLING_PLANS
   ```

6. Deploy (or run the deploy workflow by hand), then check `Release.plans_status()` says `for sale (sandbox: admins only)`.
7. Signed in as an admin with a key from `/start`, click "Choose" on a plan, and pay with `4242 4242 4242 4242`.
   You land on `/pricing#plan`, which says "Waiting for Stripe to confirm" and then shows the plan; `/start` shows your key's new limit.
8. Click "Manage billing", cancel in the portal, and see the subscription end in the Dashboard; once Stripe sends `customer.subscription.deleted` (at once, or at the period's end), your key is back to 60 a minute.

### Live, later

Once the prices are decided, make the same products and prices in live mode, give the live restricted key **Customer portal: Write**, add the events above to the live endpoint, set the portal up in live mode, and set `BILLING_PLANS` with the live price ids.
The mode is the one `DOWNLOADS_CHECKOUT_MODE` sets, for downloads and plans alike.

## Rolling or revoking a key

In **Developers → API keys**, choose **Roll key** (or **Delete**) on `bitblocks-x402-sandbox`.
Then set the new value with the same command above.
