defmodule Bitblocks.Support.BlockScan do
  @moduledoc """
  One block read for gifts to the donation address, ahead of the sync
  (`Bitblocks.Support.Scan`, #74).
  """
  use Ecto.Schema

  schema "support_block_scans" do
    field :height, :integer
    field :block_hash, :string
    field :address, :string
    field :gift_sats, :integer, default: 0
    field :gift_txids, {:array, :string}, default: []
    field :scanned_at, :utc_datetime
  end
end
