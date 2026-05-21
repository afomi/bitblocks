defmodule Bitblocks.Repo.Migrations.SeedOrderBookProtocol do
  use Ecto.Migration

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Seed the OrderBook protocol.
    # Like Metanet's "meta" flag, OrderBook uses "orderbook" as its identifier
    # rather than a Bitcoin address.
    execute("""
    INSERT INTO protocols (address, name, version, description, category, verification_status, documentation_url, inserted_at, updated_at)
    VALUES
      (
        'orderbook',
        'OrderBook',
        1,
        'Open Order Book protocol: a permissionless marketplace for BSV-20 Ordinal tokens. Supports listing, cancellation, and atomic settlement of token trades.',
        'multi_party',
        'verified',
        'https://bitblocks.dev/docs/order-book-protocol',
        '#{now}',
        '#{now}'
      )
    ON CONFLICT (address, version) DO NOTHING;
    """)

    # Index for querying listings by token_id
    execute("""
    CREATE INDEX idx_protocol_instances_order_book_token_id
    ON protocol_instances ((parsed_data->>'token_id'))
    WHERE parsed_data->>'op' = 'list';
    """)

    # Index for querying listings by seller_address
    execute("""
    CREATE INDEX idx_protocol_instances_order_book_seller
    ON protocol_instances ((parsed_data->>'seller_address'))
    WHERE parsed_data->>'op' = 'list';
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS idx_protocol_instances_order_book_seller;")
    execute("DROP INDEX IF EXISTS idx_protocol_instances_order_book_token_id;")

    execute("""
    DELETE FROM protocols WHERE address = 'orderbook';
    """)
  end
end
