defmodule Bitblocks.Accounts.User do
  @moduledoc """
  A person who has signed in with GitHub.

  Holds only the public GitHub profile. There is deliberately no field for an
  email or an OAuth access token: bitblocks asks GitHub who you are, then
  forgets the token.

  Fields:

    * `github_id` - GitHub's numeric user id; the stable identity key (unique).
    * `login` - the GitHub username as of the last sign-in, for display.
    * `name`, `avatar_url` - display details for the nav.
    * `last_login_at` - when the person last completed the GitHub callback.
    * `admin` - whether this person is an admin. Set only by
      `Bitblocks.Release.set_admin/2`, never by a sign-in, and tied to
      `github_id`, so a renamed login can't carry it to someone else.
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
    field :admin, :boolean, default: false

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
