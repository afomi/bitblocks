defmodule Bitblocks.Timelocks.Lock do
  @moduledoc """
  One time lock found in an output's script (#76). See `Bitblocks.ScriptLocks`
  for how each is read, and the `timelocks` migration for each field.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "timelocks" do
    field :txid, :string
    field :vout, :integer
    field :op_index, :integer
    field :kind, :string
    field :block_height, :integer
    field :satoshis, :integer
    field :lock_value, :integer
    field :unlock_height, :integer
    field :unlock_time, :utc_datetime
    field :relative, :boolean, default: false
    field :enforced, :boolean
    field :conditional, :boolean, default: false
    field :branch, :string
    field :owner, :string
    field :backs_txid, :string
    field :app, :string
    field :notes, :string
    field :version, :integer

    timestamps(type: :utc_datetime)
  end
end
