# Stripe

Bitblocks uses Stripe for one thing so far: recording AI crawlers' x402 payments, through [x402_ex](https://github.com/afomi/x402_ex).
A crawler over its budget gets a 402 with a price; it pays in USDC, and each settled payment is recorded in Stripe as a machine payment.
The plan is under "Paid crawler access (x402)" in [PLAN.md](../PLAN.md).

The account is `acct_1UdHHhLYRHWWpBFF`, separate from jurisdictional's.

## Rules for keys

- Never paste a key into a Claude session, an issue, a commit or a chat.
  You set every key yourself, from your own terminal.
- A test key starts `sk_test_` or `rk_test_`, and a live key starts `sk_live_` or `rk_live_`.
  x402_ex refuses a test key on Base mainnet and a live key on Base Sepolia, so a mix-up fails closed.
- Prefer a restricted key (`rk_…`) to the full secret key (`sk_…`).
  It gives bitblocks only what it needs, and can be rolled on its own.

## 1. Make the test key

1. Sign in at https://dashboard.stripe.com and pick the bitblocks account (`acct_1UdHHhLYRHWWpBFF`).
2. Turn on **Test mode** (the toggle at the top right), or open the bitblocks sandbox if you made one.
   Keys made in test mode start `rk_test_`.
3. Open **Developers → API keys**, then **Create restricted key**.
4. Name it `bitblocks-x402-sandbox`.
5. Under permissions, set **PaymentIntents** to **Write**, and leave everything else at **None**.
   If the sandbox run is refused for a missing permission, add only the one Stripe names, and note it here.
6. Click **Create key**, then copy the key.
   Stripe shows it once.

## 2. Set it

The key goes into the bitblocks secret in AWS Secrets Manager (`bitblocks/prod`), under its own name, so it never sits beside a live key by accident.

In your own terminal, from `~/workspace/infra`:

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

## Later: live mode (not yet)

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
