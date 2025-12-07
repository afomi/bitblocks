# Fly.io Operations

## Accessing the Console

Connect to a running Fly.io instance with an IEx console:

```bash
fly ssh console --pty -C "/app/bin/bitblocks remote"
```

Or use the shorthand:

```bash
fly ssh console -C "/app/bin/bitblocks remote"
```

## Database Operations

### Count Transactions

```elixir
Bitblocks.Repo.aggregate(Bitblocks.Chain.Transaction, :count)
```

### Delete Transactions by Block Height

To delete all transactions with a block_height of 200,000 or greater:

```elixir
# From the IEx console
import Ecto.Query

Bitblocks.Repo.delete_all(
  from t in Bitblocks.Chain.Transaction,
  where: t.block_height >= 200_000
)
```

This returns a tuple `{count, nil}` where `count` is the number of deleted rows.

### Delete with Batching (for large datasets)

For millions of rows, batch the deletes to avoid timeouts:

```elixir
import Ecto.Query

defmodule Cleanup do
  def delete_transactions_above(min_height, batch_size \\ 10_000) do
    query = from t in Bitblocks.Chain.Transaction,
            where: t.block_height >= ^min_height,
            limit: ^batch_size

    case Bitblocks.Repo.delete_all(query) do
      {0, _} -> :done
      {count, _} ->
        IO.puts("Deleted #{count} transactions")
        delete_transactions_above(min_height, batch_size)
    end
  end
end

Cleanup.delete_transactions_above(200_000)
```

### Direct PostgreSQL Access

To connect directly to the Fly Postgres database:

```bash
fly postgres connect -a bitblocks-db
```

Then run SQL directly:

```sql
DELETE FROM transactions WHERE block_height >= 200000;
```

Or with batching:

```sql
DELETE FROM transactions
WHERE id IN (
  SELECT id FROM transactions
  WHERE block_height >= 200000
  LIMIT 10000
);
```

## Other Useful Commands

```bash
# List running machines
fly status

# View logs
fly logs

# Restart the app
fly apps restart

# Open a bash shell (not IEx)
fly ssh console

# Run a one-off command
fly ssh console -C "/app/bin/bitblocks eval 'Bitblocks.Repo.aggregate(Bitblocks.Chain.Transaction, :count)'"
```
