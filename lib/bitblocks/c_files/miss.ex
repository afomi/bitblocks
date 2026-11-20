defmodule Bitblocks.CFiles.Miss do
  @moduledoc """
  A BCat head the C:// index couldn't assemble, and why
  (https://github.com/afomi/bitblocks/issues/155). A head here has no
  `c_files` row: its address is unknown until a later try assembles it. See
  the `c_file_misses` migration for each field.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "c_file_misses" do
    field :txid, :string
    field :block_height, :integer
    field :kind, :string, default: "bcat"
    field :reason, :string
    field :missing_chunks, {:array, :string}, default: []
    field :version, :integer

    timestamps(type: :utc_datetime)
  end
end
