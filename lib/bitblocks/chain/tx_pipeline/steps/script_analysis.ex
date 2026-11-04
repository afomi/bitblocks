defmodule Bitblocks.Chain.TxPipeline.Steps.ScriptAnalysis do
  @moduledoc """
  `TransactionParser.analyze/1` on each row's raw: output types, protocols,
  the coinbase flag, script and template hashes, AIP signers. A tx that
  doesn't decode keeps none of these columns.
  """

  @behaviour Bitblocks.Chain.TxPipeline.Step

  alias Bitblocks.TransactionParser

  @impl true
  def name, do: "script_analysis"

  @impl true
  def description,
    do: "Classifies each output and tags protocols, coinbase, script and template hashes."

  @impl true
  def stage, do: :chunk

  @impl true
  def run_chunk(attrs_list, _block) do
    Enum.map(attrs_list, fn attrs ->
      case TransactionParser.analyze(attrs[:raw]) do
        {:ok, meta} -> Map.merge(attrs, meta)
        _ -> attrs
      end
    end)
  end
end
