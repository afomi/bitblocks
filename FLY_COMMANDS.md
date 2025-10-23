# Fly.io Quick Command Reference

## The Key Rule: Use `rpc` Not `eval`

- ✅ `rpc` - Runs code in the running application (Hackney works)
- ❌ `eval` - Starts new process without app (Hackney fails)

## Common Commands

### Sync Blocks

```bash
# Sync blocks 100001 to 200000
fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.sync_blocks(100001, 200000)'"
```

### Check Blockchain Status

```bash
# Get Bitcoin node info
fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.blockchain_info()'"
```

### Check Database Status

```bash
# Get database statistics
fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.db_stats()'"
```

### Sync Transaction Data

```bash
# Sync transactions for block 150000
fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.sync_block_transactions(150000)'"
```

### Run Migrations

```bash
# Run pending migrations
fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.migrate()'"
```

## Interactive Console

For multiple commands or exploration:

```bash
# Connect to remote console
fly ssh console -a bitblocks

# Start IEx attached to running app
app/bin/bitblocks remote

# Now run commands interactively:
Bitblocks.Release.sync_blocks(200001, 300000)
Bitblocks.Release.db_stats()
```

## Troubleshooting

### Check if app is running

```bash
fly status -a bitblocks
```

### View logs

```bash
# Real-time logs
fly logs -a bitblocks

# Filter for specific term
fly logs -a bitblocks | grep "sync"
```

### Check machine health

```bash
fly checks list -a bitblocks
```

### Restart app

```bash
fly apps restart bitblocks
```

## Deployment

```bash
# Deploy latest code
fly deploy

# Deploy and watch logs
fly deploy && fly logs -a bitblocks

# Force rebuild
fly deploy --build-only
```

## Environment Variables

```bash
# List secrets
fly secrets list -a bitblocks

# Set a secret
fly secrets set BITCOIN_NODE_URL=http://node:8332 -a bitblocks

# Unset a secret
fly secrets unset SOME_SECRET -a bitblocks
```

## SSH Access

```bash
# SSH into machine
fly ssh console -a bitblocks

# Run command via SSH
fly ssh console -a bitblocks -C "command"

# SSH with specific machine
fly ssh console -a bitblocks -s machine-id
```

## Scaling

```bash
# List machines
fly machines list -a bitblocks

# Scale VM size
fly scale vm shared-cpu-1x -a bitblocks

# Scale memory
fly scale memory 512 -a bitblocks
```

## Database

```bash
# Connect to Postgres
fly postgres connect -a your-postgres-app

# Show connection string
fly postgres db show -a your-postgres-app
```
