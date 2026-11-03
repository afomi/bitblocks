defmodule Bitblocks.ChainTiles.Tile do
  @moduledoc """
  One stored chain tile: the bytes `Bitblocks.ChainTiles.Codec` produced for
  `(level, idx)`, addressed by their content `hash`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "chain_tiles" do
    field(:level, :integer, primary_key: true)
    field(:idx, :integer, primary_key: true)
    field(:first_height, :integer)
    field(:count, :integer)
    field(:hash, :string)
    field(:bytes, :binary)
    field(:built_at, :utc_datetime)
  end
end
