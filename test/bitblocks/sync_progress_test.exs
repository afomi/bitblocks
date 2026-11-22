defmodule Bitblocks.SyncProgressTest do
  use ExUnit.Case, async: true

  alias Bitblocks.SyncProgress

  defp snapshot(overview) do
    empty = SyncProgress.empty_snapshot()
    %{empty | overview: Map.merge(empty.overview, overview)}
  end

  test "the index is at the chain tip within a day of the node" do
    assert SyncProgress.at_chain_tip?(snapshot(%{complete_through: 900_000, node_tip: 900_100}))

    assert SyncProgress.at_chain_tip?(snapshot(%{complete_through: 900_000, node_tip: 900_144}))
  end

  test "catching up is not the tip, and neither is an unknown tip" do
    refute SyncProgress.at_chain_tip?(snapshot(%{complete_through: 400_000, node_tip: 900_000}))

    refute SyncProgress.at_chain_tip?(snapshot(%{complete_through: 900_000, node_tip: 900_145}))

    refute SyncProgress.at_chain_tip?(snapshot(%{complete_through: 400_000}))
    refute SyncProgress.at_chain_tip?(SyncProgress.empty_snapshot())
  end

  test "the public tip stands in when the node height is unknown" do
    assert SyncProgress.at_chain_tip?(snapshot(%{complete_through: 900_000, public_tip: 900_010}))
  end
end
