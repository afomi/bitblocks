defmodule Bitblocks.Chain.TxPipeline.Steps.IndexTokens do
  @moduledoc "`Chain.index_tokens/1`: BSV-20/21 token outputs; a no-op unless the tx is tagged BSV20."

  @behaviour Bitblocks.Chain.TxPipeline.Step

  @impl true
  def name, do: "index_tokens"

  @impl true
  def description, do: "Indexes BSV-20 and BSV-21 token inscriptions (txs tagged BSV20 only)."

  @impl true
  def stage, do: :tx

  @impl true
  def run(tx, _block), do: Bitblocks.Chain.index_tokens(tx)
end
