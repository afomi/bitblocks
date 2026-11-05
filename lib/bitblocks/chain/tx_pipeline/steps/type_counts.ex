defmodule Bitblocks.Chain.TxPipeline.Steps.TypeCounts do
  @moduledoc """
  The block's tally of transaction types, written once the block is
  `completed`: `blocks.type_counts`, type id => how many of its txs have
  that type (a tx with two types counts once for each). `/types` sums these
  over the blocks verified complete (`Bitblocks.TxTypes.Counts`), so no page
  view counts `transactions`.

  It counts only txs typed at the current `TxPipeline.version(:tx_types)`,
  and stamps `blocks.type_counts_version` with
  `TxPipeline.version(:type_counts)` only when every tx of the block is; a
  block with any tx left untyped keeps a nil stamp, which
  `Release.backfill_tx_types/3` picks up. One aggregate on the `block_hash`
  index, and one update of the block row.
  """

  @behaviour Bitblocks.Chain.TxPipeline.Step

  import Ecto.Query

  alias Bitblocks.Chain.{Block, TxPipeline}
  alias Bitblocks.Repo

  @impl true
  def name, do: "type_counts"

  # Bump when this step's output would change; docs/DERIVED_DATA.md.
  @impl true
  def version, do: 1

  @impl true
  def description, do: "Tallies the block's txs per type into blocks.type_counts."

  @impl true
  def stage, do: :block

  @impl true
  def run_block(%Block{} = block) do
    %{counts: counts, untyped: untyped} = tally(block)
    stamp = if untyped == 0, do: TxPipeline.version(:type_counts)

    {1, _} =
      Repo.update_all(
        from(b in Block, where: b.id == ^block.id),
        set: [type_counts: counts, type_counts_version: stamp]
      )

    counts
  end

  @doc """
  The block's tally from its stored rows, without writing it: `counts`,
  type id => txs, over the txs typed at the current version, and `untyped`,
  the txs that aren't.
  """
  @spec tally(Block.t()) :: %{counts: %{String.t() => pos_integer()}, untyped: non_neg_integer()}
  def tally(%Block{hash: hash}) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT u.type, count(*)
        FROM transactions t
        LEFT JOIN LATERAL unnest(CASE WHEN t.tx_types_version = $2 THEN t.tx_types END) AS u(type)
          ON true
        WHERE t.block_hash = $1
        GROUP BY u.type
        """,
        [hash, TxPipeline.version(:tx_types)]
      )

    Enum.reduce(rows, %{counts: %{}, untyped: 0}, fn
      [nil, n], acc -> %{acc | untyped: n}
      [type, n], acc -> put_in(acc, [:counts, type], n)
    end)
  end
end
