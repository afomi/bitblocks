# Stripe

Bitblocks uses Stripe for two things:

- Recording AI crawlers' x402 payments, through [x402_ex](https://github.com/afomi/x402_ex).
  A crawler over its budget gets a 402 with a price; it pays in USDC, and each settled payment is recorded in Stripe as a machine payment.
  The plan is under "Paid crawler access (x402)" in [PLAN.md](../PLAN.md).
- Selling bulk downloads of a block range with Stripe Checkout, at the published $1.00 per GiB (https://github.com/afomi/bitblocks/issues/111).
  It is built and dormant until the keys below are set: [Bulk downloads: Checkout](#bulk-downloads-checkout).

Both go through one HTTP client, x402_ex's `X402.HTTPClient`, and tests stub Stripe the same way (`Req.Test`), so no test ever calls Stripe.

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

- The sandbox run pays 0.01 test USDC on Base Sepolia, through the public test facilitator `https://x402.org/facilitator`.
  The test USDC comes from https://faucet.circle.com, and no real money moves.
- Each paid retry should create one PaymentIntent in the Stripe test dashboard, under **Payments**, idempotent on the on-chain transaction hash.
- A replay of the same payment should be refused, and create nothing.

## 4. The deposit address

Every offer pays one deposit address, bitblocks' own, created once in Stripe and never shared with another app (x402_ex's rule: one deposit address per app).
It goes in config as `X402_PAY_TO`, in the bitblocks secret, and not in this repo.

After the sandbox key is set and a deploy has written it to the nodes, from a node:

```bash
# Dry run: names the key and the request, and calls nothing
bin/bitblocks rpc 'Bitblocks.Release.x402_create_deposit_address(network: "base")'

# Creates it, and prints only the address
bin/bitblocks rpc 'Bitblocks.Release.x402_create_deposit_address(network: "base", apply: true)'
```

It sends `POST /v1/crypto/deposit_addresses` with `network=base`, as Stripe's x402 guide shows (https://docs.stripe.com/payments/machine/x402).
The key is the one for `X402_NETWORK`: `STRIPE_SANDBOX_SECRET_KEY` on Base Sepolia, the default.
The `Stripe-Version` follows the guide: `2026-07-29.preview` with a sandbox key, `2026-05-27.preview` with a live one; `stripe_version:` overrides it.

Three things here are not yet confirmed against a real call:
- where the address sits in Stripe's response (the guide doesn't show it; we read a top-level `address`, and otherwise report only the response's top-level keys);
- which restricted-key permission the call needs beyond **PaymentIntents: Write** (the key above may be refused; add only what Stripe names, and note it here);
- whether a sandbox address on `network=base` takes Base Sepolia payments, as the guide's sandbox section implies.

Then set the address as `X402_PAY_TO`, the same way as the key:

```bash
aws-vault exec default -- ./scripts/app-secret-set.sh bitblocks X402_PAY_TO
```

## 5. Turning it on

Everything is off unless set, in the bitblocks secret (`config/runtime.exs`):

| Variable | Default | What it does |
| --- | --- | --- |
| `X402_ENABLED` | `false` | `true` offers payment on the crawler 402; it takes effect only with `X402_PAY_TO` set |
| `X402_PAY_TO` | none | the deposit address every offer pays |
| `X402_NETWORK` | `eip155:84532` | Base Sepolia; `eip155:8453` is Base mainnet |
| `X402_PRICE_ATOMIC` | `10000` | the price of one request, in USDC atomic units (10,000 is 0.01 USDC) |
| `X402_FACILITATOR` | `x402org` | the public test facilitator; the only one x402_ex v0.1 can use (mainnet's CDP fails closed) |
| `X402_PAID_PER_IP_PER_MINUTE` | `30` | paid attempts a minute from one IP, each a facilitator call |
| `X402_PAID_PER_FAMILY_PER_MINUTE` | `600` | paid attempts a minute from one crawler family, across its IPs |
| `STRIPE_SANDBOX_SECRET_KEY` | none | records payments on Base Sepolia |
| `STRIPE_SECRET_KEY` | none | records payments on Base mainnet |

The Stripe key is chosen by network, and read only when a payment is recorded; x402_ex refuses a live key on Base Sepolia and a test key on Base mainnet.
If `X402_ENABLED` is `true` without what it needs, the app logs a warning at boot and stays off.

To check it, and to finish any payment recorded on chain but not yet in Stripe (the `X402ReconcileWorker` cron does this every 10 minutes):

```bash
bin/bitblocks rpc 'Bitblocks.Release.x402_status()'
bin/bitblocks rpc 'Bitblocks.Release.x402_reconcile()'
```

`x402_status()` names the key variable and whether it is set, never its value.
Paid requests are rows in `x402_payments`: an `auth:` row per claimed authorization, and a `tx:` row per settled transaction with its PaymentIntent.

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

## Later: x402 live mode (not yet)

Live mode waits on your go, after the sandbox run is shown end to end.
It needs:
- Stripe's approval for **Stablecoins and Crypto** (Dashboard → **Settings → Payment methods**); it shows Pending until Stripe approves it.
- A live restricted key, set the same way as `STRIPE_SECRET_KEY`.
- Coinbase Developer Platform keys for the mainnet facilitator.
- The bitblocks deposit address, recorded in PLAN.md, and never shared with jurisdictional.
- A price; the proposal is 0.01 USDC a request.

## Rolling or revoking a key

In **Developers → API keys**, choose **Roll key** (or **Delete**) on `bitblocks-x402-sandbox`.
Then set the new value with the same command above.
