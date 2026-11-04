defmodule Bitblocks.Chain.TxPipeline.Steps.BlockTotals do
  @moduledoc """
  Block totals, written once the block is `completed`:

    * `sats_out`: the sum of non-coinbase outputs;
    * `fees`: the sum of non-coinbase fees, nil if any is unknown;
    * `miner_reward`: the coinbase's total output;
    * `subsidy`: from height (`subsidy/1`);
    * `burned`: the sum of burned sats;
    * `fees_verified`: the consistency check, `miner_reward <= subsidy + fees`.

  A miner may claim less than it is allowed (some early blocks and a few
  later ones did), so a reward below `subsidy + fees` still verifies; only a
  reward above it is a mismatch. A mismatch means our data is wrong, and is
  logged at error level. `fees_verified` is nil while fees are unknown.

  One aggregate over the block's rows on the `block_hash` index, and one
  update of the block row, which also stamps `blocks.tallies_version` with
  `TxPipeline.version(:block_totals)` (`docs/DERIVED_DATA.md`).
  """

  @behaviour Bitblocks.Chain.TxPipeline.Step

  import Ecto.Query

  require Logger

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Repo

  @initial_subsidy 5_000_000_000
  @halving_interval 210_000

  @impl true
  def name, do: "block_totals"

  # Bump when this step\'s output would change; docs/DERIVED_DATA.md.
  @impl true
  def version, do: 1

  @impl true
  def description,
    do:
      "Totals sats out, fees, miner reward, subsidy and burned, and checks reward <= subsidy + fees."

  @impl true
  def stage, do: :block

  @impl true
  def run_block(%Block{} = block) do
    totals = totals(block)

    {1, _} =
      Repo.update_all(
        from(b in Block, where: b.id == ^block.id),
        set:
          Map.to_list(totals) ++
            [
              tallies_version: Bitblocks.Chain.TxPipeline.version(:block_totals),
              updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
            ]
      )

    totals
  end

  @doc """
  The totals for `block` from its stored rows, without writing them. The
  backfill (`Release.backfill_tx_tallies/3`) compares these with the row.
  """
  @spec totals(Block.t()) :: map()
  def totals(%Block{hash: hash, height: height}) do
    row =
      Repo.one(
        from(t in Transaction,
          where: t.block_hash == ^hash,
          select: %{
            sats_out:
              fragment(
                "sum(?) FILTER (WHERE ? IS NOT TRUE)::bigint",
                t.total_output_satoshis,
                t.coinbase
              ),
            sats_out_unknown:
              fragment(
                "count(*) FILTER (WHERE ? IS NOT TRUE AND ? IS NULL)",
                t.coinbase,
                t.total_output_satoshis
              ),
            fees:
              fragment("sum(?) FILTER (WHERE ? IS NOT TRUE)::bigint", t.fee_satoshis, t.coinbase),
            fees_unknown:
              fragment(
                "count(*) FILTER (WHERE ? IS NOT TRUE AND ? IS NULL)",
                t.coinbase,
                t.fee_satoshis
              ),
            reward:
              fragment(
                "sum(?) FILTER (WHERE ? IS TRUE)::bigint",
                t.total_output_satoshis,
                t.coinbase
              ),
            coinbases: fragment("count(*) FILTER (WHERE ? IS TRUE)", t.coinbase),
            burned: fragment("sum(?)::bigint", t.burned_satoshis),
            burned_unknown: fragment("count(*) FILTER (WHERE ? IS NULL)", t.burned_satoshis)
          }
        )
      )

    from_sums(row, height)
  end

  @doc """
  The totals from per-block sums, the shape `totals/1` aggregates in SQL:
  `sats_out`, `fees`, `reward`, `burned` (sums, nil when there are no rows)
  and `sats_out_unknown`, `fees_unknown`, `coinbases`, `burned_unknown`
  (counts). The backfill's dry run builds these in memory.
  """
  @spec from_sums(map(), non_neg_integer()) :: map()
  def from_sums(row, height) do
    subsidy = subsidy(height)
    fees = if row.fees_unknown == 0, do: row.fees || 0
    reward = if row.coinbases == 1, do: row.reward

    %{
      sats_out: if(row.sats_out_unknown == 0, do: row.sats_out || 0),
      fees: fees,
      miner_reward: reward,
      subsidy: subsidy,
      burned: if(row.burned_unknown == 0, do: row.burned || 0),
      fees_verified: verify(height, reward, subsidy, fees)
    }
  end

  defp verify(_height, nil, _subsidy, _fees), do: nil
  defp verify(_height, _reward, _subsidy, nil), do: nil

  # A miner may claim less than subsidy + fees, never more.
  defp verify(height, reward, subsidy, fees) do
    if reward <= subsidy + fees do
      true
    else
      Logger.error(
        "TxPipeline block_totals: block #{height} miner reward #{reward} exceeds " <>
          "subsidy #{subsidy} + fees #{fees}; our tallies are wrong"
      )

      false
    end
  end

  @doc """
  The block subsidy at `height`, in satoshis: 50 BTC, halved every 210,000
  blocks (integer shift, as the node computes it), 0 after 64 halvings.
  """
  @spec subsidy(non_neg_integer()) :: non_neg_integer()
  def subsidy(height) when is_integer(height) and height >= 0 do
    case div(height, @halving_interval) do
      halvings when halvings >= 64 -> 0
      halvings -> Bitwise.bsr(@initial_subsidy, halvings)
    end
  end
end
