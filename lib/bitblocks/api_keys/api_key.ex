defmodule Bitblocks.ApiKeys.ApiKey do
  @moduledoc "An API key's record. See `Bitblocks.ApiKeys`; the key itself is never stored."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "api_keys" do
    field :name, :string
    field :token_hash, :string, redact: true
    field :prefix, :string
    field :requests_per_minute, :integer
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:name, :token_hash, :prefix, :requests_per_minute])
    |> validate_required([:name, :token_hash, :prefix, :requests_per_minute])
    |> validate_number(:requests_per_minute, greater_than: 0, less_than_or_equal_to: 100_000)
    |> unique_constraint(:token_hash)
  end
end
