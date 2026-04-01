defmodule Bitblocks.ProtocolRegistry.Protocol do
  @moduledoc """
  Schema for registered Bitcoin protocols.

  Protocols are identified by a Bitcom-style Bitcoin address and can optionally
  include covenant enforcement via sCrypt.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(consumable multi_party constraint bearer_asset access_control credential data_storage identity token other)a
  @verification_statuses ~w(unverified pending beta verified deprecated)a

  schema "protocols" do
    field :address, :string
    field :name, :string
    field :version, :integer, default: 1
    field :description, :string

    field :category, Ecto.Enum, values: @categories, default: :other
    field :verification_status, Ecto.Enum, values: @verification_statuses, default: :unverified

    # Schema definition for parsing OP_RETURN data
    field :schema, :map

    # Covenant enforcement
    field :has_covenant, :boolean, default: false
    field :covenant_hash, :string
    field :scrypt_source, :string

    # Metadata
    field :author, :string
    field :documentation_url, :string
    field :source_url, :string
    field :example_txid, :string

    # Compatibility
    field :requires, {:array, :string}, default: []
    field :conflicts_with, {:array, :string}, default: []

    has_many :stats, Bitblocks.ProtocolRegistry.ProtocolStats
    has_many :audits, Bitblocks.ProtocolRegistry.Audit
    has_many :instances, Bitblocks.ProtocolRegistry.Instance

    timestamps()
  end

  @doc false
  def changeset(protocol, attrs) do
    protocol
    |> cast(attrs, [
      :address,
      :name,
      :version,
      :description,
      :category,
      :verification_status,
      :schema,
      :has_covenant,
      :covenant_hash,
      :scrypt_source,
      :author,
      :documentation_url,
      :source_url,
      :example_txid,
      :requires,
      :conflicts_with
    ])
    |> validate_required([:address, :name])
    |> validate_format(:address, ~r/^[13][a-km-zA-HJ-NP-Z1-9]{25,34}$/,
      message: "must be a valid Bitcoin address"
    )
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint([:address, :version])
    |> unique_constraint([:name, :version])
  end

  @doc """
  Returns all valid protocol categories.
  """
  def categories, do: @categories

  @doc """
  Returns all valid verification statuses.
  """
  def verification_statuses, do: @verification_statuses

  @doc """
  Checks if a protocol has been verified (beta or verified status).
  """
  def verified?(%__MODULE__{verification_status: status}) do
    status in [:beta, :verified]
  end

  @doc """
  Checks if a protocol enforces its rules via covenant.
  """
  def enforced?(%__MODULE__{has_covenant: has_covenant}), do: has_covenant
end
