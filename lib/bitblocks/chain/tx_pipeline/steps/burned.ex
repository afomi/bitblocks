defmodule Bitblocks.Chain.TxPipeline.Steps.Burned do
  @moduledoc """
  Sums the sats locked in provably unspendable outputs (`OP_RETURN …` or
  `OP_FALSE OP_RETURN …`) into `burned_satoshis`; 0 when there are none.
  Most data outputs carry 0 sats, so most data txs burn nothing.
  """

  @behaviour Bitblocks.Chain.TxPipeline.Step

  alias Bitblocks.Chain.TxPipeline.Steps.Flows

  @impl true
  def name, do: "burned"

  # Bump when this step\'s output would change; docs/DERIVED_DATA.md.
  @impl true
  def version, do: 1

  @impl true
  def description, do: "Sums sats locked in OP_RETURN outputs into burned_satoshis."

  @impl true
  def stage, do: :chunk

  @impl true
  def run_chunk(attrs_list, _block) do
    Enum.map(attrs_list, fn attrs ->
      case Flows.of(attrs) do
        {:ok, %{outputs: outputs}} ->
          burned =
            for {sats, script} <- outputs, Flows.unspendable?(script), reduce: 0 do
              acc -> acc + sats
            end

          Map.put(attrs, :burned_satoshis, burned)

        :error ->
          attrs
      end
    end)
  end
end
