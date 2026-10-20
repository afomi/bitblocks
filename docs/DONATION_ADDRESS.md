# Donation address

How bitblocks gets its own BSV donation address, and the rules for spending from it.
It belongs with issue #26 (sponsorship) and the visibledao.com/bitblocks page.

This page covers bitblocks' operating costs only (#26).
Supporting Ryan personally through Civic Studio or Open Collective is a separate stream (#27), and the two never share a page or a ledger.

## Fundraising: next steps

Goal: sponsors cover the ~$1,000/month full node.
Do these in order; each one is small.

1. **Ship what's built.**
   Commit and deploy the working tree, then run #1 (`Release.analyze_transactions/1`).
   - [ ] `GET https://bitblocks.app/api/v1/support` returns 200 with `monthly_target_usd: 1000`.
2. **Derive the donation address** (see [Steps](#steps) below) and set `bsv_address` in `config :bitblocks, :support`.
   - [ ] The xpub check prints the same address the wallet shows.
   - [ ] `/api/v1/support` returns that `bsv_address`, and `received_sats_total` is not null.
3. **Start the books before the storefront.**
   Add this month's node bill, with its receipt, to the ledger (visible-dao `_data/bitblocks_ledger.yml`, or a plain file until that exists).
   - [ ] One real expense line exists before any sponsor is asked.
4. **Make the asks.**
   Money comes from conversations; the page is only where they link to.
   $1,000/month is four sponsors at $250.
   List 5–10 people or organisations who rely on BSV index data, then send each one a short, specific note.
   Places to look: wallet builders, indexers, Ourquity (who asked for the order book), qart's users, BSV grant programmes.
   - [ ] Five asks sent this week, each logged with a date and the reply.
5. **Ship the sponsor page** at visibledao.com/bitblocks (visible-dao inbox: `from-bitblocks-2026-10-20-sponsor-the-node.md`), then set `sponsor_url` so the bitblocks footer links to it.
   - [ ] The footer "Sponsor" link appears on bitblocks.app.

## Decision

Bitblocks gets a **dedicated address**, separate from the Visible DAO treasury (`13ycKt5iTceSbmZ1GGJgvKsoGaJPv2pVgZ`).
It is derived from the **same mnemonic**, as a **new hardened account**.

Why a separate address:
- The books stay clean, and every satoshi at the address is bitblocks' alone.
- `GET /api/v1/support` sums everything ever paid to one address. With a shared address, Visible DAO's own history would show up as bitblocks donations.

Why the same mnemonic, under a separate account:
- There is one backup to keep safe, not two.
- Hardened accounts are cryptographically isolated from each other.
  Leaking anything from account 1 (its xpub, or a child key) reveals nothing about account 0, the Visible DAO treasury.

When a separate mnemonic is better instead: if the bitblocks treasury may one day be handed to other keyholders, such as a collective or co-maintainers.
You can't give away one account of a mnemonic without giving away the whole mnemonic.
If that is likely, start a fresh mnemonic for bitblocks now, because moving the address later breaks its public history.

## Manual or wallet: use a wallet

Derive the key and do all signing **in a wallet**, not by hand.
- The mnemonic never touches a terminal, a script, shell history, the clipboard of a networked dev machine, or an AI chat.
  **Never paste the mnemonic into Claude or any other tool.**
- The wallet also handles change, coin selection and fees, which you would otherwise have to get right by hand on every spend.
- Manual derivation adds risk without adding control.
  The only manual step worth doing is the verification below, and it uses the **xpub**, which contains no secret.

ElectrumSV works well here: it imports BIP39 mnemonics with a custom derivation path and holds several accounts side by side.

## Steps

1. **Find the convention behind the published address.**
   Restore the mnemonic in the wallet and find the derivation path whose first receiving address is `13ycKt5iTceSbmZ1GGJgvKsoGaJPv2pVgZ`.
   Common candidates are `m/44'/236'/0'` (BSV's registered coin type) and `m/44'/0'/0'` (inherited from older BTC-era wallets).
   Record the path that matches here, since a path is not a secret: `________`.
   If the mnemonic is an Electrum-format seed rather than BIP39, it has no account level.
   In that case, stop and use a fresh mnemonic for bitblocks.
2. **Add account 1** at the same purpose and coin type, for example `m/44'/236'/1'`, by changing only the account index.
   Label it "bitblocks".
3. **Take account 1's first receiving address** (`…/1'/0/0`).
   That is the bitblocks donation address.
4. **Verify it from the xpub.**
   Export account 1's xpub from the wallet (it starts with `xpub`) and run:

   ```bash
   mix run --no-start -e '
   {:ok, k} = BSV.ExtKey.from_string(System.argv() |> hd())
   k |> BSV.ExtKey.derive("M/0/0") |> Map.fetch!(:pubkey)
     |> BSV.Address.from_pubkey() |> BSV.Address.to_string() |> IO.puts()
   ' -- xpub6…
   ```

   The printed address must match what the wallet shows for receiving address 0.
   Do the same with account 0's xpub, which must print `13ycKt5…`. That proves both accounts come from the same seed and the same convention.
   This snippet was checked on 2026-10-20 against a randomly generated mnemonic: deriving from the xpub and from the seed gave the same address.
5. **Publish it.**
   Set `bsv_address` in `config :bitblocks, :support`, then confirm `GET /api/v1/support` returns it.
   Give the address to visible-dao for the /bitblocks page and its QR code.

## Spending rules (keep the books honest)

- **Change must never go back to the donation address.**
  `Bitblocks.Chain.received_for_address/2` counts every output paid to the address as received.
  It can't yet tell change from a gift, so change sent back there would show up as fake donations.
  The wallet's default internal change addresses (`…/1'/1/n`) are correct, so don't turn on "send change to the same address".
- **Every spend is an expense** and gets a line in visible-dao's `_data/bitblocks_ledger.yml`, with the txid and the receipt.
- Received totals come from the chain and expenses come from the ledger. Neither one is typed in from memory.

## Optional: publish the account xpub

Publishing account 1's xpub lets anyone list every address in the account, change included, and audit the full books independently.
That is the most transparent option, and privacy doesn't matter for a public treasury.
The caveat: an xpub together with any one leaked **non-hardened** child private key exposes every key in the account.
The account is hardened from the Visible DAO treasury, so even then the damage stops at bitblocks.

## Later: Bitcom identity (#21)

Bitcom commands, such as monthly statements (`$ echo <statement> to accounts/2026-10`), must be funded from the namespace address.
If the donation address doubles as bitblocks' Bitcom namespace, each command spends a little from the treasury, and the fee is a visible expense.
The alternative is account 1's receiving address 1, a sibling address whose history stays separate.
Decide this when #21 starts.
