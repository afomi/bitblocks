defmodule Bitblocks.OrdinalCollections.RunJig do
  @moduledoc """
  Run protocol NFT collections (RelayX), Rexxies first.

  Every Run tx carries a payload output, `OP_FALSE OP_RETURN "run" <version>
  <app> <json>`, with `in` (how many leading inputs are jigs), `out` (state
  hashes of the jig outputs), `del` (deleted jigs) and `exec` (the calls). Jig
  outputs follow the payload output in Run order: the input jigs that survive,
  in input order, then the created jigs.

  **Mint:** the tx spends the collection class's current location (a chain
  link) as jig input `i` and `exec` calls `mint` on `{"$jig": i}`. The class's
  next location is output `p + 1 + i` (`p` = payload output index), and the
  minted NFTs are the created jigs after the surviving inputs. A tx that
  updates the class without minting carries the chain on with no items.

  **Landing:** a jig spent as input `vin` lands at `p + 1 + vin` when nothing
  is deleted. A spend with no Run payload destroys the jig; a tx that deletes
  jigs needs jig state to map outputs. Both are `unknown`, not guessed
  (rexxie-indexer guessed "the first dust output", which batch sends break).

  Names and traits aren't on chain for RelayX NFTs (the mint's metadata is
  empty and the image is encrypted), so they come from the collection's
  catalog (`config.catalog`), keyed by mint txid.
  """

  @behaviour Bitblocks.OrdinalCollections.Protocol

  alias Bitblocks.OrdinalCollections.Protocol
  alias Bitblocks.Ordinals.Inscription

  @impl true
  def mint(tx, txid, link, config) do
    with i when is_integer(i) <- Protocol.input_index(tx, link),
         {:ok, p, payload} <- payload(tx),
         jigs_in when is_integer(jigs_in) and i < jigs_in <- payload["in"],
         [] <- payload["del"] || [] do
      out_count = length(payload["out"] || [])
      created = max(out_count - jigs_in, 0)
      next = "#{txid}_#{p + 1 + i}"

      items =
        if mints?(payload, i) do
          entry = catalog_entry(config, txid)

          for k <- 0..(created - 1)//1 do
            vout = p + 1 + jigs_in + k

            %{
              vout: vout,
              name: entry[:name],
              content_type: nil,
              traits: entry[:traits] || [],
              owner: tx.outputs |> Enum.at(vout) |> owner_or_nil()
            }
          end
        else
          []
        end

      {:ok, items, [next]}
    else
      _ -> :no
    end
  end

  defp mints?(payload, i) do
    Enum.any?(payload["exec"] || [], fn
      %{"op" => "CALL", "data" => [%{"$jig" => ^i}, "mint" | _]} -> true
      _ -> false
    end)
  end

  defp catalog_entry(%{catalog: catalog}, txid) when is_atom(catalog),
    do: catalog.entry(txid) || %{}

  defp catalog_entry(_config, _txid), do: %{}

  @impl true
  def landing(tx, txid, vin, _value_of) do
    case payload(tx) do
      {:ok, p, %{"in" => jigs_in} = payload} when is_integer(jigs_in) ->
        cond do
          vin >= jigs_in ->
            {:unknown, "spent as a non-jig input of #{txid}"}

          (payload["del"] || []) != [] ->
            {:unknown, "#{txid} deletes jigs; output mapping needs jig state"}

          Enum.at(tx.outputs, p + 1 + vin) == nil ->
            {:unknown, "#{txid} has no jig output for input #{vin}"}

          true ->
            {:ok, "#{txid}_#{p + 1 + vin}"}
        end

      _ ->
        {:unknown, "spent outside Run in #{txid}: the jig is destroyed"}
    end
  end

  @impl true
  def owner(%BSV.TxOut{script: script}), do: Inscription.lock_owner(script)

  defp owner_or_nil(nil), do: nil
  defp owner_or_nil(out), do: owner(out)

  @doc "The Run payload: `{:ok, output_index, map}` or `:error`."
  def payload(%BSV.Tx{outputs: outputs}) do
    outputs
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {%BSV.TxOut{script: %BSV.Script{chunks: chunks}}, k} ->
      with [nop, :OP_RETURN, "run", _version, _app, json | _] when nop in [:OP_0, :OP_FALSE] <-
             chunks,
           true <- is_binary(json),
           {:ok, %{} = payload} <- Jason.decode(json) do
        {:ok, k, payload}
      else
        _ -> nil
      end
    end)
  end
end
