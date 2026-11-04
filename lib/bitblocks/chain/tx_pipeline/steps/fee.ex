defmodule Bitblocks.Chain.TxPipeline.Steps.Fee do
  @moduledoc """
  `fee_satoshis`: sats in minus sats out. A coinbase pays no fee (it
  collects them), so 0. nil while sats in is unknown, never guessed. A
  negative result means an input value is wrong; it is logged and stored
  as nil.
  """

  @behaviour Bitblocks.Chain.TxPipeline.Step

  require Logger

  alias Bitblocks.Chain.TxPipeline.Steps.Flows

  @impl true
  def name, do: "fee"

  # Bump when this step\'s output would change; docs/DERIVED_DATA.md.
  @impl true
  def version, do: 1

  @impl true
  def description, do: "Stores fee_satoshis: sats in minus sats out; 0 for a coinbase."

  @impl true
  def stage, do: :chunk

  @impl true
  def run_chunk(attrs_list, block) do
    Enum.map(attrs_list, &Map.put(&1, :fee_satoshis, fee(&1, block)))
  end

  defp fee(attrs, block) do
    with {:ok, flows} <- Flows.of(attrs) do
      cond do
        Flows.coinbase?(flows) ->
          0

        is_integer(attrs[:total_input_satoshis]) and is_integer(attrs[:total_output_satoshis]) ->
          case attrs.total_input_satoshis - attrs.total_output_satoshis do
            fee when fee >= 0 ->
              fee

            fee ->
              Logger.error(
                "TxPipeline fee: tx #{attrs[:txid]} in block #{block.height} has fee #{fee} " <>
                  "(in #{attrs.total_input_satoshis}, out #{attrs.total_output_satoshis}); stored as unknown"
              )

              nil
          end

        true ->
          nil
      end
    else
      :error -> nil
    end
  end
end
