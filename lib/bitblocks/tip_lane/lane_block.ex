defmodule Bitblocks.TipLane.LaneBlock do
  @moduledoc """
  One block a tip lane has read, or is reading, for its projection
  (`Bitblocks.TipLane`, #139). Only `read` rows under the hash the header at
  their height has now count toward the lane's coverage.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "tip_lane_blocks" do
    field :projection_id, :integer
    field :height, :integer
    field :block_hash, :string
    # read | reading | failed
    field :status, :string, default: "reading"
    # The txs kept from the block: matches, then spends of the slice's outputs.
    field :txids, {:array, :string}, default: []
    field :matched, :integer, default: 0
    field :spends, :integer, default: 0
    field :source, :string
    field :error, :string
    field :attempts, :integer, default: 0
    field :started_at, :utc_datetime
    field :read_at, :utc_datetime
  end
end
