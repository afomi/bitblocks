defmodule Bitblocks.Repo.Migrations.AddUserIdToApiKeys do
  use Ecto.Migration

  # A trial key belongs to the GitHub user who took it from /start (#59), one
  # active key each. Keys issued by hand have no user.
  def change do
    alter table(:api_keys) do
      add(:user_id, references(:users, on_delete: :nilify_all))
    end

    create(unique_index(:api_keys, [:user_id], where: "revoked_at IS NULL"))
  end
end
