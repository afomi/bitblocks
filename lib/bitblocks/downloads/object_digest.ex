defmodule Bitblocks.Downloads.ObjectDigest do
  @moduledoc """
  The sha256 of one block's object in the tx store
  (`blocks/<height>-<hash>.bin`, `Bitblocks.TxStore.BlockObject`), computed
  once when a purchase covering it is prepared. Objects are immutable, so a
  digest is never recomputed.
  """
  use Ecto.Schema

  @primary_key {:block_hash, :string, autogenerate: false}

  schema "block_object_digests" do
    field :height, :integer
    field :bytes, :integer
    field :sha256, :string
    field :inserted_at, :utc_datetime
  end
end
