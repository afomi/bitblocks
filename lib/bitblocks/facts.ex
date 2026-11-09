defmodule Bitblocks.Facts do
  @moduledoc """
  What the chain doesn't announce, for `/facts` (afomi/bitblocks#70): miner
  rewards left unclaimed, sats burned, and a supply audit, each summed from
  the block totals (`TxPipeline.Steps.BlockTotals`) and never from
  `transactions`.

  The range is exact: blocks `0..through_height`, every one verified complete
  (`Bitblocks.Sync.complete_through/0`) and totalled at the current
  `TxPipeline.version(:block_totals)` with its fees and burned sats known.
  Short of the tip the figures are partial, and the summary says which range
  they cover.

  Three coinbases can never be spent, and the block totals can't give their
  reward, because their rows aren't stored (`Bitblocks.Sync` skips them as
  short by design):

    * block 0: the genesis coinbase is not in the UTXO set;
    * blocks 91,722 and 91,812: their coinbases were repeated byte for byte at
      91,880 and 91,842, and each repeat overwrote the earlier output (BIP30).

  Each was 50 BTC. They count as issued by the schedule and as unspendable
  by consensus, apart from the unclaimed rewards.

  The supply audit is an identity over the range: the subsidy the schedule
  issued equals what miners claimed as new coins (`miner_reward - fees`),
  plus what they left unclaimed, plus the three unspendable coinbases.
  Burned sats are inside what was claimed, so what can still move is at most
  claimed minus burned. A tally that says a miner took more than it was
  allowed (`fees_verified` false) is counted and shown, since it means our
  data is wrong there.

  Cached like `TxTypes.Counts`: refreshed every 10 minutes into ETS, so a page
  view reads memory (`get/0`). One aggregate over `blocks` per refresh, plus
  the first untotalled height and the largest unclaimed rewards.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Bitblocks.Chain.{Block, TxPipeline}
  alias Bitblocks.Chain.TxPipeline.Steps.BlockTotals
  alias Bitblocks.Repo

  @table __MODULE__
  @interval :timer.minutes(10)
  @query_timeout 60_000
  @largest 10
  @unspendable_reward 5_000_000_000
  @unspendable_coinbases [
    %{height: 0, note: "The genesis coinbase, which the node never added to the UTXO set."},
    %{height: 91_722, note: "Overwritten by the same coinbase repeated at block 91,880 (BIP30)."},
    %{height: 91_812, note: "Overwritten by the same coinbase repeated at block 91,842 (BIP30)."}
  ]
  @unspendable_heights Enum.map(@unspendable_coinbases, & &1.height)

  @type summary :: %{
          required(:status) => :ok | :pending | :unavailable,
          optional(atom()) => term()
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The coinbases that can never be spent, each with its height and why."
  @spec unspendable_coinbases() :: [%{height: non_neg_integer(), note: String.t()}]
  def unspendable_coinbases, do: @unspendable_coinbases

  @doc "The cached summary, or `%{status: :pending}` before the first refresh."
  @spec get() :: summary()
  def get do
    case :ets.lookup(@table, :summary) do
      [{:summary, summary}] -> summary
      [] -> %{status: :pending}
    end
  rescue
    ArgumentError -> %{status: :pending}
  end

  @doc "Computes the summary now, stores it for `get/0`, and returns it."
  @spec refresh() :: summary()
  def refresh do
    summary = compute()
    store(summary)
    summary
  rescue
    error ->
      Logger.error("Facts: refresh failed: #{Exception.message(error)}")
      summary = %{status: :unavailable}
      if get().status != :ok, do: store(summary)
      summary
  end

  @doc """
  Computes the summary from `blocks`, without caching it:

    * `through_height`: the figures cover blocks `0..through_height`; -1 when
      block 0 isn't complete;
    * `complete_through` and `tip`, to say what is left;
    * `issued`: the subsidy the schedule issued over the range;
    * `claimed`: new coins the miners took (`miner_reward - fees`);
    * `unclaimed` and `unclaimed_blocks`: what they left, and in how many blocks;
    * `unspendable` and `unspendable_coinbases`: the three coinbases above,
      those in range;
    * `burned`, `spendable_at_most` (`claimed - burned`) and `fees`;
    * `mismatched_blocks`: blocks whose tallies fail the reward check;
    * `largest_unclaimed`: the blocks with the most left unclaimed.
  """
  @spec compute() :: summary()
  def compute do
    tip = Bitblocks.Sync.tip()
    complete_through = Bitblocks.Sync.complete_through(tip)
    through = totalled_through(complete_through, TxPipeline.version(:block_totals))

    base = %{
      status: :ok,
      through_height: through,
      complete_through: complete_through,
      tip: tip,
      version: TxPipeline.version(:block_totals),
      computed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    if through >= 0, do: Map.merge(base, figures(through)), else: base
  end

  # The highest H <= complete_through where every block 0..H, the three
  # unspendable coinbases aside, has final totals with fees and burned known.
  defp totalled_through(complete_through, _version) when complete_through < 0, do: -1

  defp totalled_through(complete_through, version) do
    first_untotalled =
      Repo.one(
        from(b in Block,
          where: b.height <= ^complete_through,
          where: b.height not in @unspendable_heights,
          where:
            is_nil(b.tallies_version) or b.tallies_version != ^version or is_nil(b.fees) or
              is_nil(b.burned) or is_nil(b.miner_reward),
          select: min(b.height)
        ),
        timeout: @query_timeout
      )

    if first_untotalled, do: first_untotalled - 1, else: complete_through
  end

  defp figures(through) do
    row =
      Repo.one(
        from(b in Block,
          where: b.height <= ^through,
          where: b.height not in @unspendable_heights,
          select: %{
            claimed: fragment("sum(? - ?)::bigint", b.miner_reward, b.fees),
            unclaimed: fragment("sum(? + ? - ?)::bigint", b.subsidy, b.fees, b.miner_reward),
            unclaimed_blocks:
              fragment("count(*) FILTER (WHERE ? + ? > ?)", b.subsidy, b.fees, b.miner_reward),
            fees: fragment("sum(?)::bigint", b.fees),
            mismatched_blocks: fragment("count(*) FILTER (WHERE ? IS FALSE)", b.fees_verified)
          }
        ),
        timeout: @query_timeout
      )

    # Burned counts in every block, the three unspendable coinbases included.
    burned =
      Repo.one(
        from(b in Block,
          where: b.height <= ^through,
          select: fragment("sum(?)::bigint", b.burned)
        ),
        timeout: @query_timeout
      ) || 0

    unspendable = Enum.filter(@unspendable_coinbases, &(&1.height <= through))
    claimed = row.claimed || 0

    %{
      issued: issued_through(through),
      claimed: claimed,
      unclaimed: row.unclaimed || 0,
      unclaimed_blocks: row.unclaimed_blocks,
      unspendable: length(unspendable) * @unspendable_reward,
      unspendable_coinbases: unspendable,
      burned: burned,
      spendable_at_most: claimed - burned,
      fees: row.fees || 0,
      mismatched_blocks: row.mismatched_blocks,
      largest_unclaimed: largest_unclaimed(through)
    }
  end

  defp largest_unclaimed(through) do
    Repo.all(
      from(b in Block,
        where: b.height <= ^through,
        where: b.height not in @unspendable_heights,
        where: b.subsidy + b.fees > b.miner_reward,
        order_by: [desc: b.subsidy + b.fees - b.miner_reward, asc: b.height],
        limit: @largest,
        select: %{
          height: b.height,
          hash: b.hash,
          unclaimed: b.subsidy + b.fees - b.miner_reward,
          miner_reward: b.miner_reward
        }
      ),
      timeout: @query_timeout
    )
  end

  @doc """
  The subsidy the schedule issued over blocks `0..through`, from the halving
  rule alone (`BlockTotals.subsidy/1`), one sum per halving era.
  """
  @spec issued_through(integer()) :: non_neg_integer()
  def issued_through(through) when through < 0, do: 0

  def issued_through(through) do
    era = 210_000

    0..div(through, era)
    |> Enum.map(fn n ->
      blocks = min(through, (n + 1) * era - 1) - n * era + 1
      blocks * BlockTotals.subsidy(n * era)
    end)
    |> Enum.sum()
  end

  defp store(summary), do: :ets.insert(@table, {:summary, summary})

  # -- Server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    refresh? = Keyword.get(opts, :refresh, Application.get_env(:bitblocks, :facts_refresh, true))

    if refresh?, do: send(self(), :refresh)
    {:ok, %{refresh: refresh?}}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()
    Process.send_after(self(), :refresh, @interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
