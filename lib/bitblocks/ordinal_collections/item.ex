defmodule Bitblocks.OrdinalCollections.Item do
  @moduledoc """
  One item of a collection (1Sat, Run or Rare Candy). See `Bitblocks.OrdinalCollections`
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
    # The tx whose B:// file is the item's image, when the mint names one.
    field :image_txid, :string
    field :current_outpoint, :string
    field :owner, :string
    # current | ended | partial | unknown | untraced (see OrdinalCollections.trace/2).
    # current and ended are settled; partial resumes on the next trace.
    field :trace_state, :string, default: "untraced"
    field :trace_reason, :string
    field :trace_source, :string
    # When the last answered trace ran.
    field :traced_at, :utc_datetime
    # The last trace attempt's failure (nil once one answers), and when it ran.
    field :trace_error, :string
    field :trace_checked_at, :utc_datetime
    # Txids the item moved through, oldest first (provenance; kept in the blob store).
    field :trail, {:array, :string}, default: []
    # Bumped by every trace write and every reorg mark (#73): a trace writes
    # only if the row still holds the version it read.
    field :trace_version, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
