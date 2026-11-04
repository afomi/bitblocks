defmodule Bitblocks.Sync.Settings do
  @moduledoc """
  The sync loop's persisted operator settings: one row (id 1).

  `concurrency` is blocks worked at once; `paused` stops new dispatch while
  blocks already dispatched finish (#44).
  """
  use Ecto.Schema

  schema "sync_settings" do
    field :concurrency, :integer
    field :paused, :boolean, default: false
    timestamps()
  end
end
