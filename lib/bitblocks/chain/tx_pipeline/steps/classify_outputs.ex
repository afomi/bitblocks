defmodule Bitblocks.Chain.TxPipeline.Steps.ClassifyOutputs do
  @moduledoc """
  Types each tx against `priv/data/tx_types/types.json`
  (`Bitblocks.TxTypes.Classifier`): every output gets a type id, unmatched
  is `custom`, and the tx's type is the set of them, written to `tx_types`
  and stamped `tx_types_version` (afomi/bitblocks#49). A tx that doesn't
  decode keeps both nil, so the backfill picks it up.
  """

  @behaviour Bitblocks.Chain.TxPipeline.Step

  alias Bitblocks.TxTypes.Classifier

  @impl true
  def name, do: "classify_outputs"

  # The classifier's own version: one number, kept beside the rules it
  # versions (Classifier.version/0). docs/DERIVED_DATA.md.
  @impl true
  def version, do: Classifier.version()

  @impl true
  def description,
    do: "Types every output against types.json, unmatched as custom, and the tx as their set."

  @impl true
  def stage, do: :chunk

  @impl true
  def run_chunk(attrs_list, block) do
    stamp = Bitblocks.Chain.TxPipeline.version(:tx_types)

    Enum.map(attrs_list, fn attrs ->
      case Classifier.classify_raw(attrs[:raw], block: block) do
        {:ok, %{types: types}} -> Map.merge(attrs, %{tx_types: types, tx_types_version: stamp})
        {:error, _} -> attrs
      end
    end)
  end
end
