defmodule Bitblocks.Chain.TxPipeline.Steps.RecordSpends do
  @moduledoc "`Chain.record_spends/1`: one `spend_index` row per input, and order-book settlement."

  @behaviour Bitblocks.Chain.TxPipeline.Step

  @impl true
  def name, do: "record_spends"

  @impl true
  def description, do: "Records which outpoints each input spends in spend_index."

  @impl true
  def stage, do: :tx

  @impl true
  def run(tx, _block), do: Bitblocks.Chain.record_spends(tx)
end
