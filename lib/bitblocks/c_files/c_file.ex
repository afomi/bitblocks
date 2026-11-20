defmodule Bitblocks.CFiles.CFile do
  @moduledoc """
  One B:// file output in the C:// index, keyed by the sha256 of its bytes
  (`Bitblocks.CFiles`). See the `c_files` migration for each field.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "c_files" do
    field :sha256, :binary
    field :txid, :string
    field :vout, :integer
    field :block_height, :integer
    field :media_type, :string
    field :encoding, :string
    field :filename, :string
    field :size, :integer
    field :version, :integer

    timestamps(type: :utc_datetime)
  end
end
