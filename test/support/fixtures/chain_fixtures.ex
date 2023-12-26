defmodule Bitblocks.ChainFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Bitblocks.Chain` context.
  """

  @doc """
  Generate a block.
  """
  def block_fixture(attrs \\ %{}) do
    {:ok, block} =
      attrs
      |> Enum.into(%{
        size: 42,
        timestamp: ~N[2023-10-27 00:02:00],
        version: 42,
        time: 42,
        bits: "some bits",
        hash: "some hash",
        num_tx: 42,
        chainwork: "some chainwork",
        difficulty: 42,
        height: 42,
        mediantime: 42,
        merkleroot: "some merkleroot",
        nextblockhash: "some nextblockhash",
        prevblockhash: "some prevblockhash",
        nonce: 42
      })
      |> Bitblocks.Chain.create_block()

    block
  end

  @doc """
  Generate a block.
  """
  def block_fixture(attrs \\ %{}) do
    {:ok, block} =
      attrs
      |> Enum.into(%{
        size: 42,
        timestamp: ~N[2023-12-22 06:00:00],
        version: 42,
        time: 42,
        bits: "some bits",
        hash: "some hash",
        num_tx: 42,
        chainwork: "some chainwork",
        difficulty: 42,
        height: 42,
        mediantime: 42,
        merkleroot: "some merkleroot",
        nextblockhash: "some nextblockhash",
        prevblockhash: "some prevblockhash",
        nonce: 42
      })
      |> Bitblocks.Chain.create_block()

    block
  end
end
