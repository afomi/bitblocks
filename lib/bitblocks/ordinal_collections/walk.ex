defmodule Bitblocks.OrdinalCollections.Walk do
  @moduledoc """
  A finished walk of a collection's mint chain. See the `collection_walks`
  migration for each field's meaning.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "collection_walks" do
    field :collection_id, :string
    field :finished_at, :utc_datetime
    field :mints, :integer
    field :items, :integer

    timestamps(type: :utc_datetime)
  end
end
