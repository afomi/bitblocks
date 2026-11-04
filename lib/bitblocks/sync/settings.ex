defmodule Bitblocks.Sync.Settings do
  @moduledoc "The sync loop's persisted operator settings: one row (id 1)."
  use Ecto.Schema

  schema "sync_settings" do
    field :concurrency, :integer
    timestamps()
  end
end
