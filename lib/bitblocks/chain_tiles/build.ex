defmodule Bitblocks.ChainTiles.Build do
  @moduledoc """
  One run of the chain-tile builder. `mode` is `full` or `incremental`;
  `status` is `running`, `ok` or `failed`. The newest `ok` row's
  `started_at` is the watermark the next incremental run scans from.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "chain_tile_builds" do
    field(:mode, :string)
    field(:status, :string)
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)
    field(:tip_height, :integer)
    field(:tiles_written, :integer, default: 0)
    field(:tiles_unchanged, :integer, default: 0)
    field(:leaves_scanned, :integer, default: 0)
    field(:error, :string)
  end
end
