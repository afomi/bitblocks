defmodule Bitblocks.ProtocolRegistry.ProtocolStats do
  @moduledoc """
  Statistics for protocol usage over time.

  Tracks instance counts, transaction counts, unique addresses,
  and other metrics for protocols.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @periods ~w(all_time daily weekly monthly)

  schema "protocol_stats" do
    belongs_to :protocol, Bitblocks.ProtocolRegistry.Protocol

    field :period, :string
    field :period_start, :date

    # Counters
    field :instance_count, :integer, default: 0
    field :transaction_count, :integer, default: 0
    field :unique_addresses, :integer, default: 0
    field :total_satoshis, :integer, default: 0

    # First/last seen
    field :first_seen_txid, :string
    field :first_seen_at, :utc_datetime
    field :last_seen_txid, :string
    field :last_seen_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(stats, attrs) do
    stats
    |> cast(attrs, [
      :protocol_id,
      :period,
      :period_start,
      :instance_count,
      :transaction_count,
      :unique_addresses,
      :total_satoshis,
      :first_seen_txid,
      :first_seen_at,
      :last_seen_txid,
      :last_seen_at
    ])
    |> validate_required([:protocol_id, :period])
    |> validate_inclusion(:period, @periods)
    |> unique_constraint([:protocol_id, :period, :period_start])
  end

  @doc """
  Returns all valid period types.
  """
  def periods, do: @periods
end
