defmodule Bitblocks.Repo.Migrations.AddAdminToUsers do
  use Ecto.Migration

  # Admin is a flag on the person's own row, keyed by their GitHub numeric id
  # (users.github_id), not a list of emails or logins in the environment.
  # A renamed or re-registered GitHub login can't inherit it. Set with
  # Release.set_admin/2; nothing a sign-in writes can change it.
  # users is a small table, so the default writes no noticeable load.
  def change do
    alter table(:users) do
      add(:admin, :boolean, null: false, default: false)
    end
  end
end
