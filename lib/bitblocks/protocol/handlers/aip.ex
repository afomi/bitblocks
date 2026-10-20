defmodule Bitblocks.Protocol.Handlers.Aip do
  @moduledoc """
  Author Identity Protocol — verifies the signature (see `Bitblocks.Aip`).
  """

  use Bitblocks.Protocol.Handler,
    name: "AIP",
    prefix: "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva"

  @impl true
  def parse(data_chunks) when is_list(data_chunks) do
    case data_chunks |> Enum.map(&to_cell/1) |> Bitblocks.Aip.signatures() do
      [] ->
        {:error, :no_aip}

      [first | _] = signatures ->
        {:ok,
         %{
           protocol: "AIP",
           signer: first.address,
           valid: first.valid,
           signatures: signatures
         }}
    end
  end

  # OpReturn.parse_data/1 chunk maps back to the raw cells AIP signs over.
  defp to_cell(%{type: :push_data, hex: hex}), do: Base.decode16!(hex, case: :mixed)
  defp to_cell(%{type: :opcode, name: name}), do: String.to_existing_atom(name)
  defp to_cell(%{hex: hex}), do: Base.decode16!(hex, case: :mixed)
end
