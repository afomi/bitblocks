defmodule Bitblocks.ApiKeys.ApiKey do
  @moduledoc "An API key's record. See `Bitblocks.ApiKeys`; the key itself is never stored."

  use Ecto.Schema
  import Ecto.Changeset

  @scopes ~w(ops_read)

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

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:name, :token_hash, :prefix, :requests_per_minute, :scopes])
    |> validate_required([:name, :token_hash, :prefix, :requests_per_minute])
    |> validate_number(:requests_per_minute, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_subset(:scopes, @scopes)
    |> unique_constraint(:token_hash)
  end
end
