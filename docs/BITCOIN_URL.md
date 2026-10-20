# Bitcoin URL Schemes for Payment

This document outlines how URLs/hyperlinks can encode enough information to generate a Bitcoin transaction, enabling QR code-based payments at point of sale systems.

## Chain Variations

Different Bitcoin-derived chains use different URI schemes:

| Chain | URI Scheme | Example |
|-------|------------|---------|
| Bitcoin (BTC) | `bitcoin:` | `bitcoin:bc1q...?amount=0.001` |
| Bitcoin SV (BSV) | `bitcoin:` | `bitcoin:1ABC...?amount=0.001` |
| Bitcoin Cash (BCH) | `bitcoincash:` | `bitcoincash:qpm2qsz...?amount=0.001` |
| Litecoin | `litecoin:` | `litecoin:LTC1q...?amount=1.5` |
| Ethereum | `ethereum:` | `ethereum:0x89...?value=1e18` |

### Why the Differences?

- **BTC and BSV** both use `bitcoin:` because they share heritage
- **BCH** adopted `bitcoincash:` ([BUIP-55](https://github.com/BitcoinUnlimited/BUIP/blob/master/055.mediawiki)) to prevent users accidentally sending BCH to BTC addresses
- Address formats provide additional disambiguation:
  - BTC: Bech32 (`bc1q...`) or legacy (`1...`, `3...`)
  - BSV: Legacy only (`1...`)
  - BCH: CashAddr (`bitcoincash:qpm2...`) or legacy

### BSV-Specific Considerations

BSV maintains the original `bitcoin:` scheme but has additional ecosystem tools:

1. **Paymail** - Human-readable addresses (`user@domain.com`)
2. **Money Button** - Embedded payment widgets
3. **HandCash Connect** - OAuth-style payment authorization
4. **Relay/RelayX** - One-click payments

## BIP-21: The Standard Bitcoin URI Scheme

The canonical format defined in [BIP-21](https://github.com/bitcoin/bips/blob/master/bip-0021.mediawiki):

```
bitcoin:<address>[?amount=<amount>][&label=<label>][&message=<message>]
```

### Examples

```
bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa
bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa?amount=0.001
bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa?amount=0.001&label=Satoshi&message=Pizza
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| address   | Yes      | Bitcoin address (P2PKH, P2SH, or Bech32) |
| amount    | No       | Amount in BTC (decimal) |
| label     | No       | Label for the address (for address book) |
| message   | No       | Message describing the transaction |

## BIP-72: Payment Protocol URLs

Extends BIP-21 with a `r` parameter pointing to a Payment Protocol request:

```
bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa?r=https://merchant.com/pay/invoice123
```

The `r` parameter URL returns a `PaymentRequest` protobuf containing:
- Network (mainnet/testnet)
- Outputs (addresses and amounts)
- Expiration time
- Merchant data
- PKI signature for verification

## BSV-Specific: Paymail

Paymail replaces raw addresses with human-readable handles:

```
payto:ryan@ryanwold.net?amount=0.001&purpose=coffee
```

The wallet resolves `ryan@ryanwold.net` via:
1. `GET https://ryanwold.net/.well-known/bsvalias`
2. Discover capability URLs
3. `POST` to payment destination endpoint
4. Receive fresh address for payment

## Extended URL Scheme for POS Systems

A comprehensive POS URL might include:

```
bitcoin:1ABC...?amount=0.00123&label=CoffeeShop&message=Order%2012345&r=https://pos.example.com/invoice/12345&callback=https://pos.example.com/paid/12345
```

### Proposed Additional Parameters

| Parameter  | Description |
|------------|-------------|
| `r`        | Payment Protocol URL for signed invoice |
| `callback` | Webhook URL to notify on payment |
| `expires`  | Unix timestamp when offer expires |
| `currency` | Fiat currency for display (USD, EUR) |
| `fiat`     | Fiat amount (wallet converts to BTC) |
| `merchant` | Merchant identifier |
| `order`    | Order/invoice reference |

### Example: Full POS URL

```
bitcoin:1CoffeeShopAddr123?amount=0.00045&fiat=25.00&currency=USD&label=Bean%20Counter%20Cafe&message=Order%20%231234&order=1234&merchant=bean-counter&expires=1704067200&callback=https://pos.beancounter.cafe/api/paid/1234
```

## QR Code Generation

### Size Considerations

QR codes have capacity limits based on error correction level:

| EC Level | Numeric | Alphanumeric | Binary |
|----------|---------|--------------|--------|
| L (7%)   | 7,089   | 4,296        | 2,953  |
| M (15%)  | 5,596   | 3,391        | 2,331  |
| Q (25%)  | 3,993   | 2,420        | 1,663  |
| H (30%)  | 3,057   | 1,852        | 1,273  |

A typical Bitcoin URI fits easily, but keep URLs short for reliable scanning.

### Best Practices

1. **Use uppercase for address** - QR alphanumeric mode is more efficient
2. **Minimize parameters** - Only include essential data
3. **URL-encode values** - Spaces become `%20`, etc.
4. **Include amount** - Reduces user error
5. **Add expiration** - Prevents stale payments

## Minimal vs Complete URLs

### Minimal (Address Only)
```
bitcoin:1ABC123...
```
- User must enter amount manually
- No merchant context
- No payment confirmation

### Standard (Amount + Label)
```
bitcoin:1ABC123...?amount=0.001&label=CoffeeShop
```
- Fixed amount
- Merchant identification
- Still requires manual broadcast confirmation

### Complete (With Payment Protocol)
```
bitcoin:?r=https://merchant.com/pay/inv123
```
- Signed invoice from merchant
- Multiple outputs supported
- Automatic payment confirmation
- Refund address included

## Implementation Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   POS       │     │   Customer  │     │   Merchant  │
│   Display   │     │   Wallet    │     │   Server    │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       │  Generate URL     │                   │
       │───────────────────>                   │
       │                   │                   │
       │  Display QR       │                   │
       │<──────────────────│                   │
       │                   │                   │
       │         Scan QR   │                   │
       │         ─────────>│                   │
       │                   │                   │
       │                   │  Fetch PaymentReq │
       │                   │──────────────────>│
       │                   │                   │
       │                   │  PaymentRequest   │
       │                   │<──────────────────│
       │                   │                   │
       │                   │  Broadcast TX     │
       │                   │──────────────────>│
       │                   │                   │
       │                   │  Payment ACK      │
       │                   │<──────────────────│
       │                   │                   │
       │  Callback: Paid   │                   │
       │<──────────────────────────────────────│
       │                   │                   │
```

## Security Considerations

1. **HTTPS required** - All callback and `r` URLs must use HTTPS
2. **Signature verification** - Payment Protocol includes PKI signatures
3. **Amount verification** - Wallet should display amount for user confirmation
4. **Expiration** - Include `expires` to prevent replay of old invoices
5. **Unique addresses** - Generate fresh address per transaction

## Standards Landscape

### What's Standard vs Conventional

| Aspect | BTC | BSV | BCH | Status |
|--------|-----|-----|-----|--------|
| BIP-21 URI | Yes | Yes | Modified | **De facto standard** |
| BIP-70 Payment Protocol | Deprecated | Yes | Yes | Controversial |
| BIP-270 (Simplified) | No | Yes | No | BSV-specific |
| Paymail | No | Yes | No | BSV ecosystem |
| CashAddr | No | No | Yes | BCH-specific |

### BIP-70: The Controversy

BIP-70 Payment Protocol was widely implemented but later deprecated by BTC Core because:
- PKI/X.509 certificate complexity
- Privacy concerns (IP address exposure)
- Centralization via certificate authorities

**BSV retained BIP-70** and created BIP-270 (simplified version without X.509).

### Modern Approaches by Chain

**BTC:**
- LNURL (Lightning Network URLs)
- BOLT-11 invoices for Lightning
- Simple BIP-21 for on-chain

**BSV:**
- Paymail (most common)
- BIP-270 for merchant integration
- Direct P2P via SPV

**BCH:**
- JSON Payment Protocol (JPP)
- CashAddr format
- Simple Payment Verification

## Unified Payment URLs (Emerging)

There's movement toward chain-agnostic payment URLs:

### EIP-681 (Ethereum)
```
ethereum:0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7?value=1e18&gas=21000
```

### CAIP-10 (Chain Agnostic)
```
caip10:eip155:1:0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7
caip10:bip122:000000000019d6689c085ae165831e93:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa
```

### Universal QR (Proposed)

A theoretical universal format:
```
pay:bsv:1ABC...?amount=0.001
pay:btc:bc1q...?amount=0.001
pay:eth:0x89...?value=1e18
```

## Recommendation for BSV POS

For a BSV point-of-sale system, use this priority:

1. **Paymail** (best UX, most adoption)
   ```
   payto:merchant@shop.com?amount=0.001&purpose=Order%201234
   ```

2. **BIP-21 with callback** (broadest wallet support)
   ```
   bitcoin:1ABC...?amount=0.001&label=Shop&r=https://shop.com/pay/1234
   ```

3. **Direct address** (fallback)
   ```
   bitcoin:1ABC...?amount=0.001
   ```

---

## Why Paymail is Recommended

### The Problem with Raw Addresses

Traditional Bitcoin payments have friction:

1. **Address reuse is bad** - Privacy and security concerns
2. **Addresses are ugly** - `1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa` is not memorable
3. **No payment confirmation** - Sender broadcasts, hopes recipient sees it
4. **No metadata** - Just an address, no context
5. **Key management** - Users must backup 256-bit keys

### What Paymail Solves

| Problem | Paymail Solution |
|---------|------------------|
| Ugly addresses | Human-readable: `ryan@wallet.com` |
| Address reuse | Fresh address generated per payment |
| No confirmation | Direct P2P delivery of transaction |
| No metadata | Sender/receiver names, purpose field |
| Discovery | DNS-based, like email |

### Why Paymail Wins for POS

1. **User Experience**
   - Customer sees `pay to: coffee@beancounter.cafe` not `1Hf7...`
   - Memorable, brandable, professional

2. **Fresh Addresses**
   - Each payment request generates a new address
   - No address reuse (better privacy, cleaner accounting)

3. **Instant Confirmation**
   - Transaction sent directly to merchant's server
   - No waiting for block confirmation for small amounts
   - Merchant can verify TX validity in milliseconds

4. **Ecosystem Adoption**
   - HandCash, MoneyButton, RelayX, Centbee all support Paymail
   - De facto standard in BSV ecosystem

5. **Extensible**
   - Built-in capability negotiation
   - Supports P2P transactions, encrypted messaging, identity verification

---

## Getting Started with Paymail

### Option 1: Use a Hosted Wallet (Easiest)

**Time: 5 minutes | Cost: Free | Technical skill: None**

Simply create an account with a Paymail-enabled wallet:

| Wallet | Paymail Format | Notes |
|--------|----------------|-------|
| HandCash | `$handle` or `handle@handcash.io` | Most popular, mobile-first |
| RelayX | `handle@relayx.io` | Web wallet, NFT support |
| Centbee | `handle@centbee.com` | Mobile, good for Africa/EU |
| MoneyButton | `handle@moneybutton.com` | Developer-focused |

**Steps:**
1. Download wallet app (HandCash, Centbee, etc.)
2. Create account (email + password)
3. Your paymail is automatically assigned
4. Start receiving payments immediately

**Limitations:**
- You don't control the domain
- Wallet provider controls your keys (custodial)
- Subject to provider's terms of service

---

### Option 2: Self-Hosted Paymail (Full Control)

**Time: 1-2 hours | Cost: Domain + hosting | Technical skill: Moderate**

Run your own Paymail server on your domain.

#### Prerequisites

1. **Domain name** - e.g., `ryanwold.net`
2. **HTTPS hosting** - SSL certificate required
3. **BSV wallet/keys** - To generate addresses
4. **Web server** - Nginx, Caddy, or cloud function

#### Self-Hosted Options

| Option | Language | Complexity | Best For |
|--------|----------|------------|----------|
| go-paymail | Go | Low | Production servers |
| paymail-server | Node.js | Low | Quick prototypes |
| Custom Phoenix | Elixir | Medium | Integration with existing Phoenix app |
| Cloudflare Workers | JS | Low | Serverless, global edge |
| AWS Lambda | Any | Medium | AWS infrastructure |

---

#### Example 1: go-paymail (Recommended for Production)

The most complete open-source implementation.

**Repository:** https://github.com/tonicpow/go-paymail

```bash
# Clone and build
git clone https://github.com/tonicpow/go-paymail.git
cd go-paymail
go build -o paymail-server ./cmd/server

# Or use Docker
docker pull tonicpow/go-paymail
```

**Configuration (config.yaml):**
```yaml
server:
  port: 3000
  domain: ryanwold.net

capabilities:
  pki: true
  paymentDestination: true
  receiveTransaction: true
  p2pPaymentDestination: true

wallet:
  # Use extended public key for address derivation
  xpub: "xpub6CUGRUonZSQ4TWt..."
  derivation_path: "m/44'/236'/0'/0"

database:
  type: sqlite  # or postgres, mysql
  path: ./paymail.db
```

**Run:**
```bash
./paymail-server --config config.yaml
```

**Features:**
- Full BRFC capability support
- SQLite/PostgreSQL/MySQL storage
- HD wallet integration
- Rate limiting
- Prometheus metrics
- Docker support

**Nginx reverse proxy:**
```nginx
server {
    listen 443 ssl;
    server_name ryanwold.net;

    ssl_certificate /etc/letsencrypt/live/ryanwold.net/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ryanwold.net/privkey.pem;

    location /.well-known/bsvalias {
        proxy_pass http://localhost:3000/.well-known/bsvalias;
    }

    location /api/v1/bsvalias/ {
        proxy_pass http://localhost:3000/api/v1/bsvalias/;
    }
}
```

---

#### Example 2: Minimal Phoenix/Elixir Implementation

For integrating Paymail into an existing Phoenix app (like Bitblocks).

**Add to router.ex:**
```elixir
scope "/.well-known", BitblocksWeb do
  pipe_through :api
  get "/bsvalias", PaymailController, :capabilities
end

scope "/api/v1/bsvalias", BitblocksWeb do
  pipe_through :api
  get "/id/:paymail", PaymailController, :pki
  post "/address/:paymail", PaymailController, :payment_destination
  post "/receive-transaction/:paymail", PaymailController, :receive_transaction
end
```

**lib/bitblocks_web/controllers/paymail_controller.ex:**
```elixir
defmodule BitblocksWeb.PaymailController do
  use BitblocksWeb, :controller
  alias Bitblocks.PaymailService

  @domain "ryanwold.net"

  def capabilities(conn, _params) do
    json(conn, %{
      bsvalias: "1.0",
      capabilities: %{
        pki: "https://#{@domain}/api/v1/bsvalias/id/{alias}@{domain.tld}",
        paymentDestination: "https://#{@domain}/api/v1/bsvalias/address/{alias}@{domain.tld}",
        "receive-transaction": "https://#{@domain}/api/v1/bsvalias/receive-transaction/{alias}@{domain.tld}"
      }
    })
  end

  def pki(conn, %{"paymail" => paymail}) do
    case PaymailService.get_identity(paymail) do
      {:ok, pubkey} ->
        json(conn, %{
          bsvalias: "1.0",
          handle: paymail,
          pubkey: pubkey
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Paymail not found"})
    end
  end

  def payment_destination(conn, %{"paymail" => paymail} = params) do
    sender_name = params["senderName"]
    amount = params["amount"]
    purpose = params["purpose"]

    case PaymailService.get_payment_destination(paymail, sender_name, amount, purpose) do
      {:ok, output_script} ->
        json(conn, %{output: output_script})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: reason})
    end
  end

  def receive_transaction(conn, %{"paymail" => paymail} = params) do
    hex = params["hex"]
    metadata = params["metadata"]
    reference = params["reference"]

    case PaymailService.receive_transaction(paymail, hex, metadata, reference) do
      {:ok, txid} ->
        json(conn, %{txid: txid, note: "Payment received"})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: reason})
    end
  end
end
```

**lib/bitblocks/paymail_service.ex:**
```elixir
defmodule Bitblocks.PaymailService do
  alias Bitblocks.Repo
  alias Bitblocks.Paymail.{Identity, Payment}

  @master_xpub "xpub6CUGRUonZSQ4TWt..."

  def get_identity(paymail) do
    case Repo.get_by(Identity, handle: paymail) do
      nil -> {:error, :not_found}
      identity -> {:ok, identity.pubkey}
    end
  end

  def get_payment_destination(paymail, sender_name, amount, purpose) do
    # Get next derivation index
    index = get_next_index(paymail)

    # Derive child key from xpub
    {:ok, child_pubkey} = derive_pubkey(@master_xpub, index)

    # Create P2PKH output script
    address = BSV.Address.from_pubkey(child_pubkey)
    output_script = BSV.Script.p2pkh_lock(address) |> BSV.Script.to_hex()

    # Store for later lookup
    %Payment{}
    |> Payment.changeset(%{
      paymail: paymail,
      index: index,
      output_script: output_script,
      sender_name: sender_name,
      amount: amount,
      purpose: purpose,
      status: "pending"
    })
    |> Repo.insert()

    {:ok, output_script}
  end

  def receive_transaction(paymail, hex, metadata, reference) do
    # Parse and validate transaction
    with {:ok, tx} <- BSV.Tx.from_hex(hex),
         :ok <- validate_outputs(tx, paymail),
         :ok <- validate_signatures(tx) do

      # Mark payment as received
      update_payment_status(reference, "received")

      # Optionally broadcast
      # BitcoinsvCli.sendrawtransaction(hex)

      {:ok, BSV.Tx.get_txid(tx)}
    end
  end

  defp get_next_index(paymail) do
    # Increment and return next index for this paymail
    Repo.one(
      from p in Payment,
      where: p.paymail == ^paymail,
      select: coalesce(max(p.index), -1)
    ) + 1
  end

  defp derive_pubkey(xpub, index) do
    # BIP32 derivation from extended public key
    BSV.ExtKey.from_string(xpub)
    |> BSV.ExtKey.derive_child(index)
    |> then(& &1.pubkey)
  end
end
```

**Database migrations:**
```elixir
# priv/repo/migrations/xxx_create_paymail_tables.exs
defmodule Bitblocks.Repo.Migrations.CreatePaymailTables do
  use Ecto.Migration

  def change do
    create table(:paymail_identities) do
      add :handle, :string, null: false
      add :pubkey, :string, null: false
      add :xpub, :string
      timestamps()
    end

    create unique_index(:paymail_identities, [:handle])

    create table(:paymail_payments) do
      add :paymail, :string, null: false
      add :index, :integer, null: false
      add :output_script, :string, null: false
      add :sender_name, :string
      add :amount, :bigint
      add :purpose, :string
      add :reference, :string
      add :txid, :string
      add :status, :string, default: "pending"
      timestamps()
    end

    create index(:paymail_payments, [:paymail])
    create index(:paymail_payments, [:reference])
    create index(:paymail_payments, [:txid])
  end
end
```

#### Protocol Overview

Paymail is built on these components:

```
┌─────────────────────────────────────────────────────────────┐
│                     PAYMAIL STACK                           │
├─────────────────────────────────────────────────────────────┤
│  DNS          │  SRV record or well-known URL              │
├───────────────┼─────────────────────────────────────────────┤
│  Discovery    │  /.well-known/bsvalias (capabilities)      │
├───────────────┼─────────────────────────────────────────────┤
│  Capabilities │  Payment destination, P2P, verification    │
├───────────────┼─────────────────────────────────────────────┤
│  Keys         │  HD wallet for address generation          │
└───────────────┴─────────────────────────────────────────────┘
```

#### Step 1: DNS Configuration

Add a SRV record (optional but recommended):

```
_bsvalias._tcp.ryanwold.net. 3600 IN SRV 10 10 443 paymail.ryanwold.net.
```

Or rely on the well-known URL fallback (simpler):
```
https://ryanwold.net/.well-known/bsvalias
```

#### Step 2: Capability Document

Create `/.well-known/bsvalias` that returns JSON:

```json
{
  "bsvalias": "1.0",
  "capabilities": {
    "pki": "https://ryanwold.net/api/v1/bsvalias/id/{alias}@{domain.tld}",
    "paymentDestination": "https://ryanwold.net/api/v1/bsvalias/address/{alias}@{domain.tld}",
    "senderValidation": "https://ryanwold.net/api/v1/bsvalias/sender-validation/{alias}@{domain.tld}",
    "verifyPublicKeyOwner": "https://ryanwold.net/api/v1/bsvalias/verifypubkey/{alias}@{domain.tld}/{pubkey}",
    "receive-transaction": "https://ryanwold.net/api/v1/bsvalias/receive-transaction/{alias}@{domain.tld}",
    "p2p-payment-destination": "https://ryanwold.net/api/v1/bsvalias/p2p-payment-destination/{alias}@{domain.tld}"
  }
}
```

#### Step 3: Implement Required Endpoints

**Minimum viable Paymail server needs:**

##### 3a. PKI (Public Key Infrastructure)
```
GET /api/v1/bsvalias/id/ryan@ryanwold.net
```
Returns:
```json
{
  "bsvalias": "1.0",
  "handle": "ryan@ryanwold.net",
  "pubkey": "02c1a2b3..."
}
```

##### 3b. Payment Destination
```
POST /api/v1/bsvalias/address/ryan@ryanwold.net
Content-Type: application/json

{
  "senderName": "Alice",
  "senderHandle": "alice@handcash.io",
  "amount": 10000,
  "purpose": "Coffee payment"
}
```
Returns:
```json
{
  "output": "76a914...88ac"
}
```

The `output` is a locking script (usually P2PKH) for a fresh address.

##### 3c. P2P Receive Transaction (Optional but Recommended)
```
POST /api/v1/bsvalias/receive-transaction/ryan@ryanwold.net
Content-Type: application/json

{
  "hex": "0100000001...",
  "metadata": {
    "sender": "alice@handcash.io",
    "note": "Thanks for coffee!"
  },
  "reference": "order-1234"
}
```
Returns:
```json
{
  "txid": "abc123...",
  "note": "Payment received"
}
```

#### Step 4: HD Wallet for Address Generation

You need to derive fresh addresses. Using an HD wallet (BIP-32):

```elixir
# Pseudocode for address generation
defmodule PaymailWallet do
  # Master key from seed
  @master_key BSV.HDKey.from_seed(seed_bytes)

  def get_fresh_address(paymail_handle) do
    # Derive unique path per payment
    index = get_next_index(paymail_handle)
    path = "m/44'/236'/0'/0/#{index}"

    child_key = BSV.HDKey.derive(@master_key, path)
    address = BSV.Address.from_pubkey(child_key.pubkey)

    # Store index -> address mapping for later lookup
    store_address(paymail_handle, index, address)

    address
  end
end
```

#### Step 5: Transaction Receiving

When a sender's wallet calls your `receive-transaction` endpoint:

1. Parse the raw transaction hex
2. Verify the transaction pays to one of your addresses
3. Verify the transaction is valid (inputs exist, signatures valid)
4. Optionally broadcast to network (or let sender broadcast)
5. Mark payment as received in your database
6. Return success to sender

---

### Option 3: Paymail-as-a-Service

**Time: 30 minutes | Cost: Free-$50/month | Technical skill: Low**

Use a service that hosts Paymail infrastructure for your domain.

#### Comprehensive Service List

| Service | Custom Domain | API Access | Pricing | Status |
|---------|---------------|------------|---------|--------|
| **Polynym** | Yes | Yes | Free tier, paid plans | Active |
| **HandCash Connect** | Yes | Yes | Revenue share model | Active |
| **RelayX** | No (relayx.io only) | Limited | Free | Active |
| **MoneyButton** | Yes | Yes | Transaction fees | Reduced activity |
| **DotWallet** | Yes | Yes | Enterprise pricing | Active (Asia focus) |
| **Centbee** | No (centbee.com only) | No | Free | Active |
| **Maxthon/VBox** | Yes | Yes | Contact for pricing | Active |
| **BitPing** | Yes | Yes | Free tier | Active |
| **Simply.Cash** | No | No | Free | Active |
| **Volt Wallet** | No | No | Free | Active |

---

#### Polynym (Recommended for Custom Domains)

**Website:** https://polynym.io

**Features:**
- Free tier with custom domain support
- REST API for programmatic access
- Multiple paymails per domain
- No wallet lock-in (bring your own keys)

**Setup Steps:**
1. Sign up at polynym.io
2. Add your domain
3. Add DNS TXT record for verification:
   ```
   _bsvalias.yourdomain.com TXT "polynym-verify=abc123"
   ```
4. Add CNAME or configure well-known redirect:
   ```
   # Option A: CNAME
   _bsvalias._tcp.yourdomain.com CNAME polynym.io.

   # Option B: Redirect /.well-known/bsvalias to Polynym
   ```
5. Create paymail handles via dashboard or API

**API Example:**
```bash
# Create a new paymail
curl -X POST https://api.polynym.io/v1/paymails \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "handle": "sales@yourdomain.com",
    "xpub": "xpub6CUGRUonZSQ4TWt..."
  }'
```

---

#### HandCash Connect (Best for Apps)

**Website:** https://handcash.io/connect

**Features:**
- OAuth-style authentication
- User pays with their HandCash wallet
- SDK for web/mobile apps
- Revenue share on transactions

**Best For:**
- Apps that want users to "Login with HandCash"
- Marketplaces, games, social apps
- When you don't want to handle keys

**Integration:**
```javascript
const { HandCashConnect } = require('@handcash/handcash-connect');

const handCashConnect = new HandCashConnect({
  appId: 'YOUR_APP_ID',
  appSecret: 'YOUR_APP_SECRET',
});

// Get user's paymail after OAuth
const account = handCashConnect.getAccountFromAuthToken(authToken);
const paymail = await account.profile.getCurrentProfile();
// Returns: { paymail: "user@handcash.io", ... }
```

---

#### DotWallet (Enterprise/Asia)

**Website:** https://www.dotwallet.com/

**Features:**
- Enterprise-grade infrastructure
- Strong presence in Asian markets
- WeChat/Alipay integration
- Multi-currency support

**Best For:**
- Businesses targeting Asian markets
- High-volume transaction processing
- Enterprise compliance requirements

---

#### BitPing (Developer-Friendly)

**Website:** https://bitping.com

**Features:**
- Free tier for developers
- Simple REST API
- Webhook notifications
- Good documentation

**Setup:**
```bash
# Verify domain ownership
curl -X POST https://api.bitping.com/v1/domains \
  -d '{"domain": "yourdomain.com"}'

# Add DNS TXT record provided
# Then create paymails via API
```

---

#### Comparison Matrix

| Need | Best Choice |
|------|-------------|
| Free custom domain | Polynym |
| App with user auth | HandCash Connect |
| Quick prototype | RelayX (use their domain) |
| Enterprise/Asia | DotWallet |
| Developer/API focus | BitPing or Polynym |
| Mobile-first users | Centbee (their domain) |

---

#### DNS Configuration (All Services)

Most services require one of these DNS setups:

**Option A: SRV Record (Preferred)**
```
_bsvalias._tcp.yourdomain.com. 3600 IN SRV 10 10 443 paymail.serviceprovider.com.
```

**Option B: Well-Known Redirect**
Configure your web server to redirect:
```
GET https://yourdomain.com/.well-known/bsvalias
→ 301 Redirect to https://serviceprovider.com/.well-known/bsvalias?domain=yourdomain.com
```

**Option C: CNAME (If Supported)**
```
paymail.yourdomain.com. CNAME serviceprovider.com.
```

---

**Steps (General):**
1. Sign up for service
2. Add your domain and verify ownership (usually DNS TXT record)
3. Configure DNS (SRV record or well-known redirect)
4. Create paymail handles via dashboard or API
5. Test with a wallet: send small amount to `test@yourdomain.com`
6. Your users get `name@yourdomain.com` paymails

---

## Paymail Protocol Deep Dive

### Resolution Flow

When someone sends to `ryan@ryanwold.net`:

```
┌──────────────┐     ┌─────────────┐     ┌─────────────────┐
│   Sender     │     │    DNS      │     │  Paymail Server │
│   Wallet     │     │             │     │  ryanwold.net   │
└──────┬───────┘     └──────┬──────┘     └────────┬────────┘
       │                    │                     │
       │ 1. SRV lookup      │                     │
       │   _bsvalias._tcp   │                     │
       │───────────────────>│                     │
       │                    │                     │
       │ 2. SRV response    │                     │
       │   (or use well-    │                     │
       │    known fallback) │                     │
       │<───────────────────│                     │
       │                    │                     │
       │ 3. GET /.well-known/bsvalias            │
       │─────────────────────────────────────────>│
       │                    │                     │
       │ 4. Capabilities JSON                     │
       │<─────────────────────────────────────────│
       │                    │                     │
       │ 5. POST /address/ryan@ryanwold.net      │
       │    {senderName, amount, purpose}        │
       │─────────────────────────────────────────>│
       │                    │                     │
       │ 6. {output: "76a914...88ac"}            │
       │<─────────────────────────────────────────│
       │                    │                     │
       │ 7. Build TX with output                 │
       │                    │                     │
       │ 8. POST /receive-transaction            │
       │    {hex: "0100...", reference}          │
       │─────────────────────────────────────────>│
       │                    │                     │
       │ 9. {txid, note: "received"}             │
       │<─────────────────────────────────────────│
       │                    │                     │
```

### Capability Extensions

Paymail is extensible. Common capabilities:

| Capability | Purpose |
|------------|---------|
| `pki` | Get public key for identity |
| `paymentDestination` | Get address for payment |
| `p2p-payment-destination` | Get output script + reference |
| `receive-transaction` | Accept TX directly (P2P) |
| `public-profile` | Name, avatar, bio |
| `sender-validation` | Verify sender identity |

### P2P vs Broadcast

**Traditional (Broadcast):**
1. Sender builds TX
2. Sender broadcasts to network
3. Recipient eventually sees it in mempool/block
4. No direct confirmation

**Paymail P2P:**
1. Sender builds TX
2. Sender POSTs TX directly to recipient's server
3. Recipient validates and acknowledges immediately
4. Recipient can broadcast (or sender does)
5. Instant confirmation for POS use cases

---

## Tools and Libraries

### Elixir/Phoenix

```elixir
# mix.exs
{:bsv, "~> 2.1.0"}  # BSV primitives
{:tesla, "~> 1.4"}  # HTTP client for resolution
```

### JavaScript/Node

```bash
npm install @moneybutton/paymail-client
npm install bsv
```

```javascript
const { PaymailClient } = require('@moneybutton/paymail-client')
const client = new PaymailClient()

// Resolve paymail to address
const output = await client.getOutputFor('ryan@ryanwold.net', {
  senderHandle: 'alice@handcash.io',
  amount: 10000,
  purpose: 'Coffee'
})
```

### Python

```bash
pip install polyglot-bitcoin
```

### Go

```bash
go get github.com/libsv/go-bk
go get github.com/tonicpow/go-paymail
```

---

## POS Integration Summary

For a complete POS system with Paymail:

### Merchant Side (Receiving)
1. Set up Paymail server (self-hosted or service)
2. Generate QR codes with `payto:pos@yourshop.com?amount=X`
3. Implement `receive-transaction` endpoint
4. Listen for incoming transactions
5. Mark orders as paid when TX received

### Customer Side (Sending)
1. Customer has Paymail wallet (HandCash, etc.)
2. Scans QR code
3. Wallet resolves paymail, gets payment address
4. Customer confirms amount
5. Wallet sends TX directly to merchant
6. Instant confirmation displayed

### Why This Works for POS

- **Speed**: P2P delivery = sub-second confirmation
- **Reliability**: Direct delivery, no mempool race
- **UX**: `pay to: coffee@shop.com` is intuitive
- **Accounting**: Each payment has unique address + reference
- **Security**: Fresh addresses, no reuse

### Paymail Flow for POS

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   POS       │     │   Customer  │     │   Paymail   │
│   Terminal  │     │   Wallet    │     │   Server    │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       │  Display QR       │                   │
       │  payto:pos@shop   │                   │
       │<──────────────────│                   │
       │                   │                   │
       │         Scan      │                   │
       │         ─────────>│                   │
       │                   │                   │
       │                   │ Resolve paymail   │
       │                   │──────────────────>│
       │                   │                   │
       │                   │ Payment dest      │
       │                   │<──────────────────│
       │                   │                   │
       │                   │ P2P tx to dest    │
       │                   │──────────────────>│
       │                   │                   │
       │  Webhook: paid    │                   │
       │<──────────────────────────────────────│
       │                   │                   │
```

## References

- [BIP-21: URI Scheme](https://github.com/bitcoin/bips/blob/master/bip-0021.mediawiki)
- [BIP-70: Payment Protocol](https://github.com/bitcoin/bips/blob/master/bip-0070.mediawiki)
- [BIP-72: Payment Protocol URIs](https://github.com/bitcoin/bips/blob/master/bip-0072.mediawiki)
- [BIP-270: Simplified Payment Protocol](https://github.com/moneybutton/bips/blob/master/bip-0270.mediawiki)
- [BIP-275: Out of Band Transaction Requests](https://github.com/moneybutton/bips/blob/master/bip-0275.mediawiki)
- [Paymail Specification](https://bsvalias.org/)
- [CAIP-10: Account ID Specification](https://github.com/ChainAgnostic/CAIPs/blob/master/CAIPs/caip-10.md)
- [EIP-681: URL Format for Transaction Requests](https://eips.ethereum.org/EIPS/eip-681)
