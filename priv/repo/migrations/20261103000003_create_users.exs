defmodule Bitblocks.Repo.Migrations.CreateUsers do
  @moduledoc """
  People who sign in with GitHub.

  Bitblocks keeps the public explorer open to everyone; signing in unlocks
  block and transaction detail pages, and an allowlist of GitHub logins
  (ADMIN_GITHUB_LOGINS) unlocks the operator surface.

  We store only the public GitHub profile: no email, no access token, no
  OAuth scopes beyond the default. The table stays small (one row per person
  who has ever signed in), so a plain index is fine here.
  """
  use Ecto.Migration

  def change do
    create table(:users) do
      # GitHub's numeric user id. Stable for the life of the account, unlike
      # the login, which a person can rename. This is the identity key.
      add(:github_id, :bigint, null: false)

      # The GitHub username at the last sign-in. Admin allowlisting matches
      # on this, case-insensitively, so it is refreshed on every sign-in.
      add(:login, :string, null: false)

      # Display name and avatar from the public profile, for the nav.
      add(:name, :string)
      add(:avatar_url, :string)

      # When this person last completed the GitHub callback.
      add(:last_login_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:users, [:github_id]))
  end
end
