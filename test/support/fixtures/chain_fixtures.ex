defmodule Bitblocks.ChainFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Bitblocks.Chain` context.
  """

  @doc """
  Generate a unique block hash.
  """
  def unique_block_hash, do: "hash#{System.unique_integer([:positive])}"

  @doc """
  Generate a unique block height.
  """
  def unique_block_height, do: System.unique_integer([:positive])

  @doc """
  Generate a block.
  """
  def block_fixture(attrs \\ %{}) do
    {:ok, block} =
      attrs
      |> Enum.into(%{
        bits: "some bits",
        chainwork: "some chainwork",
        difficulty: "120.5",
        hash: unique_block_hash(),
        height: unique_block_height(),
        mediantime: 42,
        merkleroot: "some merkleroot",
        nextblockhash: "some nextblockhash",
        nonce: 42,
        num_tx: 42,
        prevblockhash: "some prevblockhash",
        size: 42,
        time: 42,
        timestamp: ~N[2023-12-30 20:27:00],
        version: 1,
        tx: []
      })
      |> Bitblocks.Chain.create_block()

    block
  end

  @doc """
  Generate a unique transaction txid.
  """
  def unique_transaction_txid, do: "txid#{System.unique_integer([:positive])}"

  @doc """
  Generate a transaction.
  """
  def transaction_fixture(attrs \\ %{}) do
    {:ok, transaction} =
      attrs
      |> Enum.into(%{
        block_hash: "some block_hash",
        block_height: 100,
        inputs: [],
        outputs: [],
        raw: "some raw",
        txid: unique_transaction_txid(),
        version: "1",
        total_input_satoshis: 100_000_000,
        total_output_satoshis: 99_900_000
      })
      |> Bitblocks.Chain.create_transaction()

    transaction
  end
end
