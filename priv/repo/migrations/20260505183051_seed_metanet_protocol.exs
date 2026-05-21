defmodule Bitblocks.Repo.Migrations.SeedMetanetProtocol do
  use Ecto.Migration

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Seed the Metanet protocol.
    # Unlike Bitcom protocols that use a Bitcoin address, Metanet uses a
    # 4-byte flag ("meta") as its identifier.
    execute("""
    INSERT INTO protocols (address, name, version, description, category, verification_status, documentation_url, inserted_at, updated_at)
    VALUES
      (
        'meta',
        'Metanet',
        1,
        'Metanet protocol: a directed acyclic graph (DAG) layered on BSV transactions. Nodes are identified by public key and linked to parents via signature, forming content hierarchies with domain-like paths.',
        'data_storage',
        'verified',
        'https://metanet.planaria.network/',
        '#{now}',
        '#{now}'
      )
    ON CONFLICT (address, version) DO NOTHING;
    """)

    # Index for fast child lookups: find all Metanet instances whose
    # parent_txid matches a given txid.
    execute("""
    CREATE INDEX idx_protocol_instances_parent_txid
    ON protocol_instances ((parsed_data->>'parent_txid'))
    WHERE parsed_data->>'parent_txid' IS NOT NULL;
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS idx_protocol_instances_parent_txid;")

    execute("""
    DELETE FROM protocols WHERE address = 'meta';
    """)
  end
end
