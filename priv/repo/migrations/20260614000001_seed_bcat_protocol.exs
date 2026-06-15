defmodule Bitblocks.Repo.Migrations.SeedBcatProtocol do
  use Ecto.Migration

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    execute("""
    INSERT INTO protocols (address, name, version, description, category, verification_status, documentation_url, inserted_at, updated_at)
    VALUES (
      '15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A',
      'BCat',
      1,
      'BCat large-file protocol. Splits data across multiple chunk transactions referenced by a head transaction. Head tx has info/mime/encoding/filename/flag metadata then raw txid bytes for each chunk; chunk txs carry a single "c" discriminator after the prefix.',
      'data_storage',
      'verified',
      'https://bcat.bico.media/',
      '#{now}',
      '#{now}'
    )
    ON CONFLICT (address, version) DO NOTHING;
    """)
  end

  def down do
    execute("""
    DELETE FROM protocols WHERE address = '15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A';
    """)
  end
end
