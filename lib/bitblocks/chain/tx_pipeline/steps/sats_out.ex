defmodule Bitblocks.Chain.TxPipeline.Steps.SatsOut do
  @moduledoc "Sums each tx's outputs into `total_output_satoshis`, from its raw bytes."

  @behaviour Bitblocks.Chain.TxPipeline.Step

  alias Bitblocks.Chain.TxPipeline.Steps.Flows

  @impl true
  def name, do: "sats_out"

  # Bump when this step\'s output would change; docs/DERIVED_DATA.md.
  @impl true
  def version, do: 1

  @impl true
  def description, do: "Sums the tx's output values into total_output_satoshis."

  @impl true
  def stage, do: :chunk

  @impl true
  def run_chunk(attrs_list, _block) do
    Enum.map(attrs_list, fn attrs ->
      case Flows.of(attrs) do
        {:ok, %{outputs: outputs}} ->
          Map.put(attrs, :total_output_satoshis, outputs |> Enum.map(&elem(&1, 0)) |> Enum.sum())

        :error ->
          attrs
      end
    end)
  end
end
