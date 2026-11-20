defmodule Bitblocks.TipLane.Lane do
  @moduledoc """
  One projection's tip lane (#139): where it starts and whether it runs.
  How far it reaches is computed (`Bitblocks.TipLane.through/1`), never
  stored, the same rule as `complete_through`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "tip_lanes" do
    belongs_to :projection, Bitblocks.Projections.Projection
    field :from_height, :integer
    # running | stopped
    field :status, :string, default: "running"
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
