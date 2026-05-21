defmodule Bitblocks.Chain.Spend do
  @moduledoc """
  Records that an outpoint (txid, vout) was consumed by a specific input.

  One row per spent output. Absence of a row means unspent (live UTXO).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "spend_index" do
    # The output being spent
    field :txid, :string
    field :vout, :integer

    # The input that spent it
    field :spending_txid, :string
    field :spending_vin, :integer

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(spend, attrs) do
    spend
    |> cast(attrs, [:txid, :vout, :spending_txid, :spending_vin])
    |> validate_required([:txid, :vout, :spending_txid, :spending_vin])
    |> validate_number(:vout, greater_than_or_equal_to: 0)
    |> validate_number(:spending_vin, greater_than_or_equal_to: 0)
    |> unique_constraint([:txid, :vout])
  end
end
