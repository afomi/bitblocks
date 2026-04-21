defmodule Bitblocks.Repo.Migrations.SeedTwetchRelayxRunProtocols do
  use Ecto.Migration

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    execute("""
    INSERT INTO protocols (address, name, version, description, category, verification_status, documentation_url, inserted_at, updated_at)
    VALUES
      (
        '19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU',
        'Twetch',
        1,
        'Twetch social media post protocol. OP_RETURN data includes post content, reply references, and payment routing.',
        'data_storage',
        'verified',
        'https://twetch.com',
        '#{now}',
        '#{now}'
      ),
      (
        '1LtyME6b5AnMopQrBPLk4FGN8UBuhxKqrn',
        'RelayX',
        1,
        'RelayX transfer and payment protocol used by the RelayX wallet and exchange.',
        'other',
        'verified',
        'https://relayx.com',
        '#{now}',
        '#{now}'
      ),
      (
        'run://.',
        'Run',
        1,
        'Run token and smart contract protocol. Identified by OP_0 OP_RETURN 72756e (hex for "run") envelope prefix.',
        'token',
        'verified',
        'https://run.network',
        '#{now}',
        '#{now}'
      )
    ON CONFLICT (address, version) DO NOTHING;
    """)
  end

  def down do
    execute("""
    DELETE FROM protocols
    WHERE address IN (
      '19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU',
      '1LtyME6b5AnMopQrBPLk4FGN8UBuhxKqrn',
      'run://.'
    );
    """)
  end
end
