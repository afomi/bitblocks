defmodule Bitblocks.Chain.TxPipeline.Steps.IndexBitcom do
  @moduledoc "`Chain.index_bitcom/1`: Bitcom `$` commands and ownership proofs; a no-op unless tagged Bitcom."

  @behaviour Bitblocks.Chain.TxPipeline.Step

  @impl true
  def name, do: "index_bitcom"

  @impl true
  def description, do: "Logs Bitcom $ commands and ownership proofs (txs tagged Bitcom only)."

  @impl true
  def stage, do: :tx

  @impl true
  def run(tx, _block), do: Bitblocks.Chain.index_bitcom(tx)
end
