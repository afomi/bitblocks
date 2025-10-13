defmodule Bitblocks.MissingRangesTest do
  use Bitblocks.DataCase

  alias Bitblocks.Chain
  alias Bitblocks.Chain.Block

  describe "missing_block_ranges/2" do
    test "returns full range when no blocks exist" do
      assert Chain.missing_block_ranges(0, 5) == [{0, 5}]
    end

    test "identifies gaps between stored heights" do
      insert_block(0)
      insert_block(1)
      insert_block(4)

      assert Chain.missing_block_ranges(0, 5) == [{2, 3}, {5, 5}]
    end

    test "handles inverted ranges gracefully" do
      assert Chain.missing_block_ranges(10, 5) == []
    end
  end

  defp insert_block(height) do
    %Block{}
    |> Block.changeset(%{height: height, hash: "hash-#{height}"})
    |> Bitblocks.Repo.insert!()
  end
end
