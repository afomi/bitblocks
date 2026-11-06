defmodule Bitblocks.Repo.Migrations.AddRecipientVersionToProtocolInstances do
  use Ecto.Migration

  # The stamp on a token row (#69): which version of the index_tokens step read
  # the output's lock, so the holder fields in parsed_data (recipient, lock,
  # cosigner) carry their provenance. Nil on rows of other protocols, and on
  # token rows from before the stamp: those are what
  # Release.backfill_token_recipients/3 picks up. docs/DERIVED_DATA.md.
  def change do
    alter table(:protocol_instances) do
      add(:recipient_version, :integer)
    end
  end
end
