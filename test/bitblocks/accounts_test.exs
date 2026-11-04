defmodule Bitblocks.AccountsTest do
  use Bitblocks.DataCase, async: true

  alias Bitblocks.Accounts
  alias Bitblocks.Accounts.User

  defp github_auth(overrides \\ %{}) do
    info =
      Map.merge(
        %{nickname: "satoshi", name: "Satoshi", image: "https://avatars.example/1.png"},
        Map.get(overrides, :info, %{})
      )

    %Ueberauth.Auth{
      provider: :github,
      uid: Map.get(overrides, :uid, 42),
      info: struct(Ueberauth.Auth.Info, info),
      credentials: %Ueberauth.Auth.Credentials{token: "gho_secret_token"}
    }
  end

  test "a first GitHub sign-in creates the user from the public profile" do
    assert {:ok, %User{} = user} = Accounts.upsert_github_user(github_auth())

    assert user.github_id == 42
    assert user.login == "satoshi"
    assert user.name == "Satoshi"
    assert user.avatar_url == "https://avatars.example/1.png"
    assert %DateTime{} = user.last_login_at
  end

  test "a later sign-in updates the same user instead of adding one" do
    {:ok, first} = Accounts.upsert_github_user(github_auth())

    {:ok, second} =
      Accounts.upsert_github_user(github_auth(%{info: %{nickname: "renamed", name: "New"}}))

    assert second.id == first.id
    assert second.login == "renamed"
    assert second.name == "New"
    assert Repo.aggregate(User, :count) == 1
  end

  test "the access token is never stored" do
    {:ok, user} = Accounts.upsert_github_user(github_auth())

    refute inspect(Repo.reload!(user)) =~ "gho_secret_token"
    refute :token in User.__schema__(:fields)
  end

  test "a string uid from the provider is accepted" do
    assert {:ok, %User{github_id: 7}} = Accounts.upsert_github_user(github_auth(%{uid: "7"}))
  end
end
