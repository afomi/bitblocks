defmodule Bitblocks.Bap.Record do
  @moduledoc """
  One BAP record with a valid AIP signature. See `Bitblocks.Bap` and the
  `bap_records` migration for each field's meaning.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "bap_records" do
    field :txid, :string
    field :vout, :integer
    field :action, :string
    field :bap_id, :string
    field :address, :string
    field :signer, :string
    field :attestation_hash, :string
    field :seq, :string
    field :profile, :map
    field :version, :integer

    timestamps(type: :utc_datetime)
  end
end
