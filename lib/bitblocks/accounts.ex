defmodule Bitblocks.Accounts do
  @moduledoc """
  People who sign in with GitHub (see `Bitblocks.Accounts.User`).

  Sign-in is the only way a user row is written: `upsert_github_user/1` takes
  the `Ueberauth.Auth` struct from the GitHub callback and creates or
  refreshes the row keyed on GitHub's numeric id.
  """
  import Ecto.Query, warn: false

  alias Bitblocks.Accounts.User
  alias Bitblocks.Repo

  @doc "The user with this database id, or nil."
  @spec get_user(integer() | nil) :: User.t() | nil
  def get_user(nil), do: nil
  def get_user(id), do: Repo.get(User, id)

  @doc "The user with this GitHub numeric id, or nil."
  @spec get_user_by_github_id(integer()) :: User.t() | nil
  def get_user_by_github_id(github_id), do: Repo.get_by(User, github_id: github_id)

  @doc """
  Create or refresh a user from a GitHub `Ueberauth.Auth`.

  Reads only the public profile (uid, nickname, name, image). The OAuth
  credentials in the struct are ignored and never stored.
  """
  @spec upsert_github_user(Ueberauth.Auth.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def upsert_github_user(%Ueberauth.Auth{uid: uid, info: info}) do
    github_id = to_integer(uid)

    attrs = %{
      github_id: github_id,
      login: info && info.nickname,
      name: info && info.name,
      avatar_url: info && info.image,
      last_login_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    (get_user_by_github_id(github_id) || %User{})
    |> User.github_changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Makes the user with this GitHub login an admin (`true`) or not (`false`).
  The login is matched case-insensitively against the last sign-in's login;
  the flag stays on the row, keyed by `github_id`. The person must have
  signed in once. Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  @spec set_admin(String.t(), boolean()) :: {:ok, User.t()} | {:error, :not_found}
  def set_admin(login, admin?) when is_binary(login) and is_boolean(admin?) do
    wanted = login |> String.trim() |> String.downcase()

    case Repo.one(from u in User, where: fragment("lower(?)", u.login) == ^wanted) do
      nil -> {:error, :not_found}
      user -> user |> Ecto.Changeset.change(admin: admin?) |> Repo.update()
    end
  end

  defp to_integer(uid) when is_integer(uid), do: uid

  defp to_integer(uid) when is_binary(uid) do
    case Integer.parse(uid) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_integer(_), do: nil
end
