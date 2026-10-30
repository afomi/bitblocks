defmodule Bitblocks.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  # API keys (#12, #13, #29 step 5): a caller such as qart's server gets its
  # own rate budget instead of sharing its IP's anonymous one.
  #
  # token_hash          — sha256 (hex) of the key; the key itself is shown
  #                       once at creation and never stored.
  # prefix              — the key's first characters, to tell keys apart.
  # requests_per_minute — this key's budget, counted cluster-wide.
  # revoked_at          — set to stop the key; revoked keys get a 401.
  def change do
    create table(:api_keys) do
      add(:name, :string, null: false)
      add(:token_hash, :string, null: false)
      add(:prefix, :string, null: false)
      add(:requests_per_minute, :integer, null: false)
      add(:revoked_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:api_keys, [:token_hash]))
  end
end
