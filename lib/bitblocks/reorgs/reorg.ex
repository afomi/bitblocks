defmodule Bitblocks.Reorgs.Reorg do
  @moduledoc """
  One reorganization this index has seen.

  `outcome` is `resolved` when headers were fetched again from the fork
  point, or `needs_attention` when the fork was deeper than tip sync will
  rewind on its own.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @outcomes ~w(resolved needs_attention)

  @type t :: %__MODULE__{}

  schema "reorgs" do
    field(:detected_at, :utc_datetime)
    field(:last_seen_at, :utc_datetime)
    field(:fork_height, :integer)
    field(:fork_point, :integer)
    field(:orphan_count, :integer)
    field(:outcome, :string)
    field(:summary, :string)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(reorg, attrs) do
    reorg
    |> cast(attrs, [
      :detected_at,
      :last_seen_at,
      :fork_height,
      :fork_point,
      :orphan_count,
      :outcome,
      :summary
    ])
    |> validate_required([:detected_at, :last_seen_at, :fork_height, :outcome, :summary])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_number(:fork_height, greater_than_or_equal_to: 0)
  end
end
