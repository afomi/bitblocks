defmodule Bitblocks.Usage.Rollup do
  @moduledoc """
  One hour of one caller's use of one endpoint class (`Bitblocks.Usage`).
  Written only by `Bitblocks.Usage.flush/0`, as an additive upsert, so each
  node adds its own counts to the same row.
  """
  use Ecto.Schema

  @counters [
    :requests,
    :status_4xx,
    :status_5xx,
    :response_bytes,
    :duration_us,
    :db_us,
    :db_queries,
    :node_calls,
    :woc_calls,
    :coingecko_calls,
    :other_calls,
    :upstream_us
  ]

  schema "usage_rollups" do
    field :hour, :utc_datetime
    field :caller_kind, :string
    field :caller_id, :string, default: ""
    field :endpoint_class, :string

    for counter <- @counters do
      field counter, :integer, default: 0
    end

    timestamps(type: :utc_datetime)
  end

  @doc "The counter columns, in the order `Bitblocks.Usage` keeps them in ETS."
  def counters, do: @counters
end
