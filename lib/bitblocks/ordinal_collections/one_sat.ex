defmodule Bitblocks.OrdinalCollections.OneSat do
  @moduledoc """
  1Sat ordinal collections minted through a contract chain (Bubblemint).

  **Mint:** the tx spends a chain link and inscribes at least one 1-sat
  `collectionItem` whose MAP names this collection; its output 0 carries the
  mint contract on to the next mint. The MAP alone is only a claim: without
  the spend, a copycat inscription is not a mint.

  **Landing:** a 1Sat sat in input `i` sits at the offset equal to the value of
  inputs `0..i-1`, and lands in the output whose range covers that offset. If
  that output isn't 1 sat, the ordinal is no longer tracked (`unknown`).
  """

  @behaviour Bitblocks.OrdinalCollections.Protocol

  alias Bitblocks.OrdinalCollections.Protocol
  alias Bitblocks.Ordinals.Inscription

  @impl true
  def mint(tx, txid, link, %{id: cid}) do
    items = items_in(tx, cid)

    if items != [] and Protocol.input_index(tx, link) != nil,
      do: {:ok, items, ["#{txid}_0"]},
      else: :no
  end

  defp items_in(%BSV.Tx{outputs: outputs}, cid) do
    for {out, vout} <- Enum.with_index(outputs),
        out.satoshis == 1,
        {:ok, insc} <- [Inscription.parse(out.script)],
        insc.map["subType"] == "collectionItem",
        is_map(insc.map["subTypeData"]),
        insc.map["subTypeData"]["collectionId"] == cid do
      %{
        vout: vout,
        name: insc.map["name"],
        content_type: insc.content_type,
        traits: traits(insc.map["subTypeData"]),
        owner: insc.owner
      }
    end
  end

  defp traits(%{"attributes" => attrs}) when is_list(attrs) do
    for %{"name" => name} = attr <- attrs do
      details = attr["details"] || %{}
      %{"name" => name, "value" => details["name"], "description" => details["description"]}
    end
  end

  defp traits(_), do: []

  @impl true
  def landing(tx, txid, vin, value_of) do
    with {:ok, offset} <- input_offset(tx, vin, value_of) do
      tx.outputs
      |> Enum.with_index()
      |> Enum.reduce_while(0, fn {out, k}, start ->
        if offset < start + out.satoshis,
          do: {:halt, {k, out.satoshis}},
          else: {:cont, start + out.satoshis}
      end)
      |> case do
        {k, 1} -> {:ok, "#{txid}_#{k}"}
        {_k, sats} when is_integer(sats) -> {:unknown, "sat moved into a #{sats}-sat output"}
        _ -> {:unknown, "sat went to fees"}
      end
    else
      :error -> {:unknown, "input values of #{txid} unavailable"}
    end
  end

  defp input_offset(tx, vin, value_of) do
    tx.inputs
    |> Enum.take(vin)
    |> Enum.reduce_while({:ok, 0}, fn input, {:ok, sum} ->
      case value_of.(input.outpoint) do
        {:ok, sats} -> {:cont, {:ok, sum + sats}}
        :error -> {:halt, :error}
      end
    end)
  end

  @impl true
  def owner(%BSV.TxOut{script: script}), do: Inscription.lock_owner(script)
end
