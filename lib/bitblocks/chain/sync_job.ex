defmodule Bitblocks.Chain.SyncJob do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sync_jobs" do
    field :scope, :string
    field :start_block, :integer
    field :end_block, :integer
    field :status, :string
    field :blocks_synced, :integer, default: 0
    field :total_blocks, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :errors_count, :integer, default: 0
    field :error_message, :string

    timestamps()
  end

  @doc false
  def changeset(sync_job, attrs) do
    sync_job
    |> cast(attrs, [
      :scope,
      :start_block,
      :end_block,
      :status,
      :blocks_synced,
      :total_blocks,
      :started_at,
      :completed_at,
      :errors_count,
      :error_message
    ])
    |> validate_required([:scope, :start_block, :end_block, :status, :started_at])
    |> validate_inclusion(:status, ["running", "completed", "stopped", "failed"])
  end
end
