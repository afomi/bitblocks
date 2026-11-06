defmodule Bitblocks.Bitcom.Snapshot do
  @moduledoc """
  One version of the Bitcom registry export: canonical JSON and its sha256
  (#21). The version is the row's `id`. See `Bitblocks.Bitcom.Snapshots`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "bitcom_snapshots" do
    field :sha256, :string
    field :body, :string
    field :namespaces, :integer
    field :anchor_txid, :string

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:sha256, :body, :namespaces, :anchor_txid])
    |> validate_required([:sha256, :body, :namespaces])
    |> unique_constraint(:sha256)
  end
end
