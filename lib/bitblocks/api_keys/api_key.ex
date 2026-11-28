defmodule Bitblocks.ApiKeys.ApiKey do
  @moduledoc "An API key's record. See `Bitblocks.ApiKeys`; the key itself is never stored."

  use Ecto.Schema
  import Ecto.Changeset

  # ops_read: opens /api/v1/ops/*. unbudgeted: no rate budget at all, never a
  # 429 or a 402, still metered (BitblocksWeb.Plugs.RateLimiter).
  @scopes ~w(ops_read unbudgeted)

  @type t :: %__MODULE__{}

  @doc "The scopes a key can hold."
  def scopes, do: @scopes

  schema "api_keys" do
    field :name, :string
    field :token_hash, :string, redact: true
    field :prefix, :string
    field :requests_per_minute, :integer
    # What the key may do beyond its rate budget; none unless granted by name.
    field :scopes, {:array, :string}, default: []
    field :revoked_at, :utc_datetime
    # The user a trial key belongs to; nil on a key issued by hand.
    belongs_to :user, Bitblocks.Accounts.User
    # The address whose signature took this key (#121); nil otherwise.
    field :address, :string
    # The challenge that signature redeemed, so each one works once.
    field :challenge_nonce, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(key, attrs) do
    key
    |> cast(attrs, [
      :name,
      :token_hash,
      :prefix,
      :requests_per_minute,
      :scopes,
      :user_id,
      :address,
      :challenge_nonce
    ])
    |> validate_required([:name, :token_hash, :prefix, :requests_per_minute])
    |> validate_number(:requests_per_minute, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_subset(:scopes, @scopes)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:user_id)
    |> unique_constraint(:address)
    |> unique_constraint(:challenge_nonce)
  end
end
