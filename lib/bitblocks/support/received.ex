defmodule Bitblocks.Support.Received do
  @moduledoc """
  What one transaction gave an address, for the donation totals
  (`Bitblocks.Support`, docs/DONATION_ADDRESS.md).

  A gift is an output paid to the address. A transaction that spends from
  the address gives it nothing: what it pays back there is change. A spend
  is recognised by a P2PKH unlock, its last push a public key whose hash is
  the address's. An input whose unlock can't be read counts as someone
  else's, so a gift is never dropped for want of a script.

  Inputs and outputs are the node's `vin` and `vout` maps, as stored on
  `transactions.inputs` and `outputs` (JSON) and as WhatsOnChain serves them.
  """

  @sats_per_bsv 100_000_000

  @doc "Sats `vout` pays to `address`, or 0 when `vin` spends from it."
  @spec sats(String.t(), [map()], [map()]) :: non_neg_integer()
  def sats(address, vin, vout) do
    case BSV.Address.from_string(address) do
      {:ok, %{pubkey_hash: pkh}} ->
        if Enum.any?(vin, &spends_from?(&1, pkh)), do: 0, else: paid(address, vout)

      _ ->
        paid(address, vout)
    end
  end

  defp paid(address, vout) do
    Enum.sum_by(vout, fn output ->
      case get_in(output, ["scriptPubKey", "addresses"]) do
        [^address | _] -> to_sats(output["value"])
        _ -> 0
      end
    end)
  end

  defp spends_from?(%{"scriptSig" => %{"hex" => hex}}, pkh) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, script} -> last_pubkey(script) |> hash160() == pkh
      :error -> false
    end
  end

  defp spends_from?(_input, _pkh), do: false

  # A P2PKH unlock ends with a push of a 33-byte (compressed) or 65-byte key.
  defp last_pubkey(script) do
    size = byte_size(script)

    cond do
      size >= 34 and :binary.at(script, size - 34) == 33 -> binary_part(script, size - 33, 33)
      size >= 66 and :binary.at(script, size - 66) == 65 -> binary_part(script, size - 65, 65)
      true -> nil
    end
  end

  defp hash160(nil), do: nil
  defp hash160(key), do: :crypto.hash(:ripemd160, :crypto.hash(:sha256, key))

  defp to_sats(value) when is_number(value), do: round(value * @sats_per_bsv)
  defp to_sats(_value), do: 0
end
