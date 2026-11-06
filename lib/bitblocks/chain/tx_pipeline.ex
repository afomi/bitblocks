defmodule Bitblocks.Chain.TxPipeline do
  @moduledoc """
  What happens after a transaction comes in: the one place that says so.

  `steps/0` is the ordered list, and the source of truth. `docs/TX_PIPELINE.md`
  depicts it, and a test checks that the doc lists exactly these steps.

  Three stages, run by `Chain.TxIngest` and `FetchTransactionsWorker`:

    1. `:chunk` steps run before the insert, over a chunk of a block's txs in
       block order, and add columns to the rows (`run_chunk/2`).
    2. `:tx` steps run after the insert, once per stored tx (`run_tx/2`).
    3. `:block` steps run once when the block becomes `completed`
       (`run_block/1`).

  Plain function calls in order: no process, no queue. A step that raises is
  logged at error level and reported as a `[:bitblocks, :tx_pipeline,
  :step_failed]` telemetry event. A failing `:tx` step rolls its tx back
  (`TxIngest` runs the insert and these steps in one database transaction),
  so the chunk fails, the block isn't completed, and the retry redoes the
  whole tx: no silent gaps in spends, tokens or Bitcom rows. A failing
  `:block` step only leaves that block's totals unset.

  Adding a step: write one module implementing `TxPipeline.Step`, add it to
  `@steps` below, and add its row to `docs/TX_PIPELINE.md` and
  `docs/DERIVED_DATA.md`.

  ## Versions and provenance

  Every step has a `version/0`. `version/1` sums them into the version of a
  stage (`:chunk`, `:tx`, `:block`) or of a derivation, a group of steps
  whose output one row records with one stamp (`derivations/0`):

    * `:script_analysis` stamps `transactions.script_analysis_version`;
    * `:tallies` stamps `transactions.tallies_version`;
    * `:block_totals` stamps `blocks.tallies_version`;
    * `:tx_types` stamps `transactions.tx_types_version`;
    * `:type_counts` stamps `blocks.type_counts_version`;
    * `:token_recipients` stamps `protocol_instances.recipient_version`.

  A sum, so it reads at a glance ("tallies v4: four steps at v1") and only
  goes up: a bump in any step, or a new step, raises it, and every row
  stamped with the old sum is then below it. Removing a step would lower
  it, so a removal also bumps a remaining step of the same derivation by at
  least the removed step's version. A row with a nil or lower stamp is what
  a backfill picks up (`docs/DERIVED_DATA.md`).
  """

  require Logger

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Chain.TxPipeline.Steps

  @steps [
    # :chunk, before the insert
    Steps.ScriptAnalysis,
    Steps.SatsOut,
    Steps.Burned,
    Steps.SatsIn,
    Steps.Fee,
    Steps.ClassifyOutputs,
    # :tx, after the insert
    Steps.RecordSpends,
    Steps.IndexTokens,
    Steps.IndexBitcom,
    Steps.IndexBap,
    # :block, at completion
    Steps.BlockTotals,
    Steps.TypeCounts
  ]

  # Derivations: steps whose output a row stamps with one version.
  # ScriptAnalysis stamps its own (TransactionParser.analyze/1 returns it per
  # row, only for a tx that decodes); run_chunk/2 stamps :tallies,
  # Steps.BlockTotals stamps :block_totals, Steps.ClassifyOutputs stamps
  # :tx_types per row it types, and Steps.TypeCounts stamps :type_counts. A
  # block's type counts depend on the classifier too, so :type_counts sums
  # both steps: a classifier bump marks every block's counts below it.
  # Tokens stamps :token_recipients on each token row whose lock it read.
  @derivations [
    script_analysis: %{
      steps: [Steps.ScriptAnalysis],
      stamp: "transactions.script_analysis_version",
      backfill: "Release.backfill_script_analysis/3"
    },
    tallies: %{
      steps: [Steps.SatsOut, Steps.Burned, Steps.SatsIn, Steps.Fee],
      stamp: "transactions.tallies_version",
      backfill: "Release.backfill_tx_tallies/3"
    },
    block_totals: %{
      steps: [Steps.BlockTotals],
      stamp: "blocks.tallies_version",
      backfill: "Release.backfill_tx_tallies/3"
    },
    tx_types: %{
      steps: [Steps.ClassifyOutputs],
      stamp: "transactions.tx_types_version",
      backfill: "Release.backfill_tx_types/3"
    },
    type_counts: %{
      steps: [Steps.ClassifyOutputs, Steps.TypeCounts],
      stamp: "blocks.type_counts_version",
      backfill: "Release.backfill_tx_types/3"
    },
    token_recipients: %{
      steps: [Steps.IndexTokens],
      stamp: "protocol_instances.recipient_version",
      backfill: "Release.backfill_token_recipients/3"
    }
  ]

  @doc "Every step, in the order it runs."
  @spec steps() :: [module()]
  def steps, do: @steps

  @doc "The steps of one stage, in order."
  @spec steps(:chunk | :tx | :block) :: [module()]
  def steps(stage), do: Enum.filter(@steps ++ extra_steps(stage), &(&1.stage() == stage))

  @doc """
  The derivations, in order: `{name, %{steps:, stamp:, backfill:}}`, where
  `stamp` names the column that records the version per row and `backfill`
  the command that brings older rows up to it.
  """
  @spec derivations() :: keyword(map())
  def derivations, do: @derivations

  @doc """
  The version of a stage (`:chunk`, `:tx`, `:block`) or a derivation
  (`:script_analysis`, `:tallies`, `:block_totals`, `:tx_types`,
  `:type_counts`, `:token_recipients`): the sum of its steps' versions. See the moduledoc for why a sum.
  """
  @spec version(atom()) :: pos_integer()
  def version(stage) when stage in [:chunk, :tx, :block] do
    @steps |> Enum.filter(&(&1.stage() == stage)) |> sum_versions()
  end

  def version(derivation) do
    case Keyword.fetch(@derivations, derivation) do
      {:ok, %{steps: steps}} -> sum_versions(steps)
      :error -> raise ArgumentError, "no stage or derivation #{inspect(derivation)}"
    end
  end

  defp sum_versions(steps), do: steps |> Enum.map(& &1.version()) |> Enum.sum()

  @doc "The steps of a derivation, in run order."
  @spec derivation_steps(atom()) :: [module()]
  def derivation_steps(derivation), do: Keyword.fetch!(@derivations, derivation).steps

  # Tests add a step (e.g. one that raises) without editing the list.
  defp extra_steps(:tx), do: Application.get_env(:bitblocks, :tx_pipeline_extra_tx_steps, [])
  defp extra_steps(_), do: []

  @doc """
  Runs the `:chunk` steps over `attrs_list` (row attrs for a chunk of
  `block`'s txs, in block order) and returns the attrs with their columns
  added. A step that raises leaves the attrs as they were.

  Each row is stamped `tallies_version: version(:tallies)` when every tally
  step ran, and left unstamped (nil, so a backfill picks it up) when one
  raised. Script analysis stamps its own version per row.
  """
  @spec run_chunk([map()], Block.t()) :: [map()]
  def run_chunk([], _block), do: []

  def run_chunk(attrs_list, %Block{} = block) do
    {attrs_list, failed} =
      Enum.reduce(steps(:chunk), {attrs_list, []}, fn step, {acc, failed} ->
        case guarded(step, block, fn -> step.run_chunk(acc, block) end) do
          {:ok, result} when is_list(result) and length(result) == length(acc) ->
            {result, failed}

          _ ->
            {acc, [step | failed]}
        end
      end)

    if Enum.any?(derivation_steps(:tallies), &(&1 in failed)) do
      attrs_list
    else
      version = version(:tallies)
      Enum.map(attrs_list, &Map.put(&1, :tallies_version, version))
    end
  end

  @doc """
  Runs the `:tx` steps for one stored tx. Returns `{step_name, :ok | {:error,
  message}}` per step, in order.
  """
  @spec run_tx(Transaction.t(), Block.t()) :: [{String.t(), :ok | {:error, String.t()}}]
  def run_tx(%Transaction{} = tx, %Block{} = block) do
    for step <- steps(:tx) do
      {step.name(), status(guarded(step, block, fn -> step.run(tx, block) end, tx.txid))}
    end
  end

  @doc """
  Runs the `:block` steps for a block that has just become `completed`.
  Returns `{step_name, :ok | {:error, message}}` per step, in order.
  """
  @spec run_block(Block.t()) :: [{String.t(), :ok | {:error, String.t()}}]
  def run_block(%Block{} = block) do
    for step <- steps(:block) do
      {step.name(), status(guarded(step, block, fn -> step.run_block(block) end))}
    end
  end

  defp status({:ok, _}), do: :ok
  defp status(error), do: error

  defp guarded(step, block, fun, txid \\ nil) do
    {:ok, fun.()}
  rescue
    e ->
      message = Exception.message(e)
      where = if txid, do: " tx #{txid}", else: ""

      Logger.error(
        "TxPipeline step #{step.name()} failed for block #{block.height}#{where}: #{message}"
      )

      :telemetry.execute(
        [:bitblocks, :tx_pipeline, :step_failed],
        %{count: 1},
        %{step: step.name(), height: block.height, txid: txid, message: message}
      )

      {:error, message}
  end
end
