defmodule Bitblocks.Accounts.User do
  @moduledoc """
  A person who has signed in with GitHub.

  Holds only the public GitHub profile. There is deliberately no field for an
  email or an OAuth access token: bitblocks asks GitHub who you are, then
  forgets the token. Verified email addresses are read at sign-in only to
  decide admin (`ADMIN_EMAILS`); only the ones that match go in the session.

  Fields:

    * `github_id` - GitHub's numeric user id; the stable identity key (unique).
    * `login` - the GitHub username as of the last sign-in, for display.
    * `name`, `avatar_url` - display details for the nav.
    * `last_login_at` - when the person last completed the GitHub callback.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :github_id, :integer
    field :login, :string
    field :name, :string
    field :avatar_url, :string
    field :last_login_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a GitHub sign-in: the public profile plus the sign-in time."
  @spec github_changeset(t(), map()) :: Ecto.Changeset.t()
  def github_changeset(user, attrs) do
    user
    |> cast(attrs, [:github_id, :login, :name, :avatar_url, :last_login_at])
    |> validate_required([:github_id, :login])
    |> unique_constraint(:github_id)
  end
end
