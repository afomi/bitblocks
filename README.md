# Bitblocks

<p align="center">
  <strong>Bitcoin SV blockchain explorer and data sync tool</strong>
</p>

---

Bitblocks is a Phoenix/Elixir application that syncs Bitcoin SV blockchain data from a Bitcoin SV node and provides a web interface to explore blocks and transactions. It connects to a BSV node via RPC, stores blockchain data in PostgreSQL, and serves it through Phoenix LiveView.

## Features

- **Blockchain Sync**: Efficiently sync blocks and transactions from a Bitcoin SV node
- **Web Explorer**: Browse blocks and transactions through a clean web interface
- **Phoenix LiveView**: Real-time, interactive UI without complex JavaScript
- **PostgreSQL Storage**: Reliable storage of blockchain data with optimized indexes
- **RPC Integration**: Direct connection to Bitcoin SV node via JSON-RPC

## Prerequisites

- **Bitcoin SV Full Node** with RPC access (required - this app syncs directly from a node)
- **Elixir** 1.18 or later
- **Phoenix** 1.7.11
- **PostgreSQL** (any recent version)
- **Node.js** (for asset compilation)

## Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/afomi/bitblocks.git
   cd bitblocks
   ```

2. **Install dependencies**
   ```bash
   mix deps.get
   ```

3. **Configure your Bitcoin SV node connection**

   Set environment variables for your Bitcoin SV node:
   ```bash
   export BITCOIN_NODE_URL=http://your-node-ip:8332
   export BITCOIN_NODE_RPC_USERNAME=your_rpc_username
   export BITCOIN_NODE_RPC_PASSWORD=your_rpc_password
   export BITCOIN_NODE_RPC_URL=http://your-node-ip:8332
   ```

4. **Setup the database**
   ```bash
   mix ecto.create
   mix ecto.migrate
   ```

5. **Install and build assets**
   ```bash
   mix assets.setup
   mix assets.build
   ```

## Usage

### Starting the Server

Start the Phoenix server:
```bash
mix phx.server
```

Or start it inside IEx (Interactive Elixir) for debugging and manual operations:
```bash
iex -S mix phx.server
```

Visit [`http://localhost:4000`](http://localhost:4000) to view the web interface.

**Note:** The web interface includes a sync dashboard at [`http://localhost:4000/sync`](http://localhost:4000/sync) for managing blockchain synchronization through the UI.

### Syncing Blockchain Data

Use IEx to sync blockchain data from your Bitcoin SV node:

```elixir
# Start the server with IEx
iex -S mix phx.server

# Sync blocks 0-1000
Bitblocks.Sync.get_blocks(0..1000)

# Sync a specific range
Bitblocks.Sync.get_blocks(100_000..200_000)

# Get full transaction data for a specific block
Bitblocks.Sync.get(100)
```

The sync process works in two stages:
1. `get_blocks/1` - Fetches block metadata and transaction IDs
2. `get/1` - Fetches full raw transaction data for each transaction in the block

### Web Interface

Once synced, you can browse the data:

- **Status Page**: [`http://localhost:4000/status`](http://localhost:4000/status)
- **Blocks List**: [`http://localhost:4000/blocks`](http://localhost:4000/blocks)
- **Block Details**: [`http://localhost:4000/blocks/:height_or_hash`](http://localhost:4000/blocks/100)
- **Transactions List**: [`http://localhost:4000/transactions`](http://localhost:4000/transactions)
- **Transaction Details**: [`http://localhost:4000/transactions/:txid`](http://localhost:4000/transactions/txid)

## Development

### Database Commands

```bash
mix ecto.create              # Create database
mix ecto.migrate             # Run migrations
mix ecto.reset               # Drop, recreate, and migrate database
```

### Testing

```bash
# Run all tests (excluding accessibility tests that require ChromeDriver)
mix test

# Run accessibility tests (requires ChromeDriver)
mix test --only accessibility_axe

# Run with visible browser for debugging
HEADLESS=false mix test --only accessibility_axe
```

**Accessibility Testing Requirements:**
- ChromeDriver must be installed: `brew install chromedriver` (macOS)
- See `test/bitblocks_web/ACCESSIBILITY.md` for full documentation

### Asset Management

```bash
mix assets.build             # Build Tailwind CSS and esbuild
mix assets.deploy            # Build and minify for production
```

## Configuration

### Bitcoin SV Node

The application requires access to a Bitcoin SV node with RPC enabled. Configure your node in `bitcoin.conf`:

```conf
server=1
rpcuser=your_username
rpcpassword=your_secure_password
rpcallowip=your_app_ip
```

### Environment Variables

- `BITCOIN_NODE_URL` - Bitcoin SV node URL (e.g., `http://localhost:8332`)
- `BITCOIN_NODE_RPC_USERNAME` - RPC username
- `BITCOIN_NODE_RPC_PASSWORD` - RPC password
- `BITCOIN_NODE_RPC_URL` - RPC endpoint URL (usually same as BITCOIN_NODE_URL)

### Production Deployment

#### Fly.io Deployment

Bitblocks includes configuration for deployment to Fly.io:

1. **Install Fly.io CLI**
   ```bash
   curl -L https://fly.io/install.sh | sh
   ```

2. **Create a Fly.io app**
   ```bash
   fly apps create your-app-name
   ```

3. **Update fly.toml**

   Edit `fly.toml` and change the app name:
   ```toml
   app = 'your-app-name'
   ```

   Update `PHX_HOST` in the `[env]` section:
   ```toml
   PHX_HOST = 'your-app-name.fly.dev'
   ```

4. **Set secrets**
   ```bash
   fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)
   fly secrets set BITCOIN_NODE_URL=http://your-node:8332
   fly secrets set BITCOIN_NODE_RPC_USERNAME=your_username
   fly secrets set BITCOIN_NODE_RPC_PASSWORD=your_password
   fly secrets set DATABASE_URL=your_postgres_url
   ```

5. **Deploy**
   ```bash
   fly deploy
   ```

#### GitHub Actions CI/CD

The project includes automated testing and deployment:

**On every push and PR:**
- Runs unit tests
- Runs accessibility tests (axe-core)
- Compiles with warnings-as-errors

**On push to `develop`:**
- Runs all tests first
- Automatically deploys to Fly.io if tests pass

**Setup:**
1. Get your Fly.io API token: `fly auth token`
2. Add it to GitHub: Repository → Settings → Secrets and variables → Actions
3. Create secret named `FLY_API_TOKEN` with your token

See `.github/workflows/ci.yml` for the full workflow configuration.

#### General Production Configuration

For other deployment platforms:

1. Set `SECRET_KEY_BASE` (generate with `mix phx.gen.secret`)
2. Set `DATABASE_URL` for your PostgreSQL instance
3. Set `PHX_HOST` to your domain
4. Configure SSL certificates if needed

See `config/runtime.exs` for production configuration details.

## Architecture

- **BitcoinsvCli** (`lib/bitcoinsv_cli.ex`) - Bitcoin SV RPC client wrapper
- **Bitblocks.Sync** (`lib/bitblocks/sync.ex`) - Blockchain synchronization logic
- **Bitblocks.Chain** (`lib/bitblocks/chain.ex`) - Data context for blocks and transactions
- **BitblocksWeb** - Phoenix web interface with LiveView

For detailed architecture documentation, see [CLAUDE.md](CLAUDE.md).

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to get started.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Links

- **GitHub**: [https://github.com/afomi/bitblocks](https://github.com/afomi/bitblocks)
- **Issues**: [https://github.com/afomi/bitblocks/issues](https://github.com/afomi/bitblocks/issues)

## Acknowledgments

Built with:
- [Phoenix Framework](https://www.phoenixframework.org/)
- [Elixir](https://elixir-lang.org/)
- [Bitcoin SV](https://bitcoinsv.io/)
