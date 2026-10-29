defmodule Bitblocks.OrdinalCollections.Item do
  @moduledoc """
  One item of a 1Sat ordinal collection. See `Bitblocks.OrdinalCollections`
  and the `collection_items` migration for each field's meaning.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "collection_items" do
    field :collection_id, :string
    field :origin, :string
    field :mint_txid, :string
    field :mint_height, :integer
    field :name, :string
    field :content_type, :string
    field :traits, {:array, :map}, default: []
    field :current_outpoint, :string
    field :owner, :string
    field :trace_state, :string, default: "untraced"
    field :trace_reason, :string
    field :trace_source, :string
    field :traced_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
