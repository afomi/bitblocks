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

  # Advisory lock key for completed_chain_fixture/1; any fixed integer.
  @fixed_chain_lock 4_150_001

  @doc """
  Fills heights 0..`through` with `completed` block rows, skipping heights
  already stored, so `Sync.complete_through/0` reaches `through` once the
  stored ones are completed too. Hashes are `"chain-<height>"`.

  Every caller inserts the same heights and hashes, so two async tests doing
  it at once could deadlock in Postgres (40P01). The fixture first takes a
  transaction-scoped advisory lock, held until the test's sandbox rolls
  back, so tests that build a fixed chain wait for each other instead.
  """
  def completed_chain_fixture(through) do
    require Ecto.Query

    Bitblocks.Repo.query!("SELECT pg_advisory_xact_lock($1)", [@fixed_chain_lock])

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
  A `completed` block at `height` whose transactions are typed: its
  `type_counts` (type id => txs) stamped at the current version, as the
  `type_counts` pipeline step leaves it (#49).
  """
  def typed_block_fixture(height, counts) do
    require Ecto.Query

    block = block_fixture(%{height: height, sync_state: "completed"})

    Bitblocks.Repo.update_all(
      Ecto.Query.from(b in Bitblocks.Chain.Block, where: b.id == ^block.id),
      set: [
        type_counts: counts,
        type_counts_version: Bitblocks.Chain.TxPipeline.version(:type_counts)
      ]
    )

    block
  end

  @doc """
  A `completed` block at `height` with final totals, as the `block_totals`
  step leaves it (#70). Options: `:fees` (0), `:reward` (subsidy + fees),
  `:burned` (0), `:verified` (true), `:version` (the current one; nil for
  totals not yet final).
  """
  def totalled_block_fixture(height, opts \\ []) do
    require Ecto.Query

    block = block_fixture(%{height: height, sync_state: "completed"})
    subsidy = Bitblocks.Chain.TxPipeline.Steps.BlockTotals.subsidy(height)
    fees = Keyword.get(opts, :fees, 0)

    Bitblocks.Repo.update_all(
      Ecto.Query.from(b in Bitblocks.Chain.Block, where: b.id == ^block.id),
      set: [
        subsidy: subsidy,
        fees: fees,
        miner_reward: Keyword.get(opts, :reward, subsidy + fees),
        burned: Keyword.get(opts, :burned, 0),
        fees_verified: Keyword.get(opts, :verified, true),
        tallies_version:
          Keyword.get(opts, :version, Bitblocks.Chain.TxPipeline.version(:block_totals))
      ]
    )

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

  @doc """
  A transaction row as older ingest left it, with no `block_height`. The
  changeset no longer stores one, but such rows remain on prod, so readers
  are still tested against them.
  """
  def heightless_transaction_fixture(attrs \\ %{}) do
    tx = attrs |> Map.put_new(:block_height, 100) |> transaction_fixture()

    Bitblocks.Repo.query!("UPDATE transactions SET block_height = NULL WHERE id = $1", [tx.id])

    %{tx | block_height: nil}
  end
end
