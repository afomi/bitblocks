defmodule Bitblocks.Repo.Migrations.AddScopesToApiKeys do
  use Ecto.Migration

  # What a key may do beyond its rate budget (#50). Empty by default, so no
  # existing key gains anything: a scope is only ever granted by name.
  # `api_keys` is a handful of rows, and a constant default rewrites nothing.
  def change do
    alter table(:api_keys) do
      add(:scopes, {:array, :string}, null: false, default: [])
    end
  end
end
