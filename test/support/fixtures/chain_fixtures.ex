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
  Fills heights 0..`through` with `completed` block rows, skipping heights
  already stored, so `Sync.complete_through/0` reaches `through` once the
  stored ones are completed too. Hashes are `"chain-<height>"`.
  """
  def completed_chain_fixture(through) do
    require Ecto.Query

    stored =
      Bitblocks.Repo.all(
        Ecto.Query.from(b in Bitblocks.Chain.Block,
          where: b.height <= ^through,
          select: b.height
        )
      )
      |> MapSet.new()

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for height <- 0..through//1, not MapSet.member?(stored, height) do
        %{
          hash: "chain-#{height}",
          height: height,
          num_tx: 1,
          tx: [],
          sync_state: "completed",
          inserted_at: now,
          updated_at: now
        }
      end

    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Bitblocks.Repo.insert_all(Bitblocks.Chain.Block, &1))

    :ok
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
