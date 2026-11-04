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
  The person's VERIFIED GitHub email addresses, trimmed and lowercased.

  ueberauth_github calls `GET /user/emails` on every callback and puts the
  list at `auth.extra.raw_info.user["emails"]`; it holds entries only when the
  `user:email` scope was granted. We keep an address only when its
  `"verified"` is exactly `true`. The profile `info.email` is never read: it
  can be unverified, and ueberauth may fill it from the primary address
  whether or not that is verified.

  Anything unexpected (no list, the call failed, a malformed entry) yields
  fewer addresses, never more.
  """
  @spec verified_github_emails(Ueberauth.Auth.t()) :: [String.t()]
  def verified_github_emails(%Ueberauth.Auth{extra: %{raw_info: %{user: %{"emails" => emails}}}})
      when is_list(emails) do
    emails
    |> Enum.flat_map(fn
      %{"email" => email, "verified" => true} when is_binary(email) ->
        [email |> String.trim() |> String.downcase()]

      _ ->
        []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def verified_github_emails(_auth), do: []

  defp to_integer(uid) when is_integer(uid), do: uid

  defp to_integer(uid) when is_binary(uid) do
    case Integer.parse(uid) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_integer(_), do: nil
end
