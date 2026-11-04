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
  `@steps` below, and add its row to `docs/TX_PIPELINE.md`.
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
    # :tx, after the insert
    Steps.RecordSpends,
    Steps.IndexTokens,
    Steps.IndexBitcom,
    # :block, at completion
    Steps.BlockTotals
  ]

  @doc "Every step, in the order it runs."
  @spec steps() :: [module()]
  def steps, do: @steps

  @doc "The steps of one stage, in order."
  @spec steps(:chunk | :tx | :block) :: [module()]
  def steps(stage), do: Enum.filter(@steps ++ extra_steps(stage), &(&1.stage() == stage))

  # Tests add a step (e.g. one that raises) without editing the list.
  defp extra_steps(:tx), do: Application.get_env(:bitblocks, :tx_pipeline_extra_tx_steps, [])
  defp extra_steps(_), do: []

  @doc """
  Runs the `:chunk` steps over `attrs_list` (row attrs for a chunk of
  `block`'s txs, in block order) and returns the attrs with their columns
  added. A step that raises leaves the attrs as they were.
  """
  @spec run_chunk([map()], Block.t()) :: [map()]
  def run_chunk([], _block), do: []

  def run_chunk(attrs_list, %Block{} = block) do
    Enum.reduce(steps(:chunk), attrs_list, fn step, acc ->
      case guarded(step, block, fn -> step.run_chunk(acc, block) end) do
        {:ok, result} when is_list(result) and length(result) == length(acc) -> result
        _ -> acc
      end
    end)
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
