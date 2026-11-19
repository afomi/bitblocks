defmodule Bitblocks.Repo.Migrations.AddSignerToApiKeys do
  use Ecto.Migration

  # A key taken by signing a bitblocks challenge (#121) is bound to the address
  # that signed it, one active key each, and records the challenge it redeemed
  # so a challenge works once. `api_keys` is a handful of rows.
  def change do
    alter table(:api_keys) do
      add(:address, :string)
      add(:challenge_nonce, :string)
    end

    create(unique_index(:api_keys, [:address], where: "revoked_at IS NULL"))
    create(unique_index(:api_keys, [:challenge_nonce]))
  end
end
