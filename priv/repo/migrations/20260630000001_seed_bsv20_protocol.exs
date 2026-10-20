defmodule Bitblocks.Repo.Migrations.SeedBsv20Protocol do
  use Ecto.Migration

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Seed the BSV20 protocol (covers BSV-20 classic + BSV-21 token inscriptions).
    # Like OrderBook's "orderbook" and Metanet's "meta", it uses a flag string
    # ("bsv20") as its identifier rather than a Bitcoin address.
    execute("""
    INSERT INTO protocols (address, name, version, description, category, verification_status, documentation_url, inserted_at, updated_at)
    VALUES
      (
        'bsv20',
        'BSV20',
        1,
        'BSV-20 / BSV-21 fungible token inscriptions (1Sat Ordinals). Indexes deploy+mint, transfer (BSV-21, id-based) and detects classic BSV-20 ticker ops. Read-only: composing and broadcasting mints lives in the wallet layer.',
        'token',
        'beta',
        'https://bitblocks.dev/docs/bsv20-tokens',
        '#{now}',
        '#{now}'
      )
    ON CONFLICT (address, version) DO NOTHING;
    """)

    # Query tokens (deploy+mint) by their id ("<txid>_<vout>"). This is the same
    # id the Open Order Book carries as token_id, so listings resolve to tokens.
    execute("""
    CREATE INDEX idx_protocol_instances_bsv20_token_id
    ON protocol_instances ((parsed_data->>'token_id'))
    WHERE parsed_data->>'op' = 'deploy+mint';
    """)

    # Query transfers (and their holder balances) by the token they reference.
    execute("""
    CREATE INDEX idx_protocol_instances_bsv20_transfer_token_id
    ON protocol_instances ((parsed_data->>'token_id'))
    WHERE parsed_data->>'op' = 'transfer';
    """)

    # Query classic BSV-20 ops by ticker.
    execute("""
    CREATE INDEX idx_protocol_instances_bsv20_tick
    ON protocol_instances ((parsed_data->>'tick'))
    WHERE parsed_data->>'tick' IS NOT NULL;
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS idx_protocol_instances_bsv20_tick;")
    execute("DROP INDEX IF EXISTS idx_protocol_instances_bsv20_transfer_token_id;")
    execute("DROP INDEX IF EXISTS idx_protocol_instances_bsv20_token_id;")
    execute("DELETE FROM protocols WHERE address = 'bsv20';")
  end
end
