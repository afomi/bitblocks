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
  is deleted. A tx that deletes jigs needs jig state to map outputs, so it is
  `unknown`, not guessed (rexxie-indexer guessed "the first dust output",
  which batch sends break).

  **Ended (#46):** a spend with no Run payload destroys a jig, since a jig can
  only move through a Run tx. The trail ends there (`{:ended, reason}`, final
  and settled) when the spent output holds Run's standard jig amount, 273
  sats (`ends_trail?/1`). That is the evidence #46's classification rests
  on: all 30 Rexxies it calls destroyed sat in 273-sat outputs. A non-Run
  spend of any other amount stays `unknown`: the 5 open doubts sat in 1-sat
  outputs, where our trace may have followed the wrong output, so their
  spend says nothing certain about the jig.

  Names and traits aren't on chain for RelayX NFTs (the mint's metadata is
  empty), so they come from the collection's catalog (`config.catalog`),
  keyed by mint txid. A collection without a catalog has unnamed items. A
  collection whose class metadata has no `isEncrypted` (PixMoji, Glossy
  Spheres) carries each image as the mint's own B:// file, so the item's
  image is that tx (`image_txid`); an encrypted one (Rexxies) has none.

  Checked against the whole class chains of PixMoji (49 mints) and Glossy
  Spheres (100 mints) (#79): one NFT per mint, no `del`, every jig in 273
  sats, and in each one `updateMetadata` call that carries the chain on with
  no items. A payload is read only as `OP_FALSE OP_RETURN "run" …`, as Run's
  own SDK does (run-sdk 0.6.41, `_extractMetadata`). Read a payload from the
  raw bytes: WhatsOnChain's decoded JSON drops the leading `OP_FALSE` from
  some outputs' script hex, which makes a Run tx look like a non-Run spend.
  """

  @behaviour Bitblocks.OrdinalCollections.Protocol

  alias Bitblocks.Bitcom.BFile
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
          image = if config[:catalog], do: nil, else: image_txid(tx, txid)

          for k <- 0..(created - 1)//1 do
            vout = p + 1 + jigs_in + k

            %{
              vout: vout,
              name: entry[:name],
              content_type: nil,
              traits: entry[:traits] || [],
              image_txid: image,
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

  # Run's standard satoshis for a jig output (the dust it locks a jig with).
  @jig_sats 273

  @doc """
  Whether a non-Run spend of an output holding `sats` ends a jig's trail: only
  Run's standard 273-sat jig output does (see the moduledoc).
  """
  @spec ends_trail?(integer()) :: boolean()
  def ends_trail?(sats), do: sats == @jig_sats

  @impl true
  def landing(tx, txid, vin, value_of) do
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
        outside_run(tx, txid, vin, value_of)
    end
  end

  defp outside_run(tx, txid, vin, value_of) do
    with %BSV.TxIn{outpoint: spent} <- Enum.at(tx.inputs, vin),
         {:ok, sats} <- value_of.(spent) do
      if ends_trail?(sats),
        do: {:ended, "spent outside Run in #{txid}: the jig is destroyed"},
        else:
          {:unknown,
           "spent outside Run in #{txid} from a #{sats}-sat output, not a #{@jig_sats}-sat jig " <>
             "output; the trace may have followed the wrong output"}
    else
      _ -> {:error, "input values of #{txid} unavailable"}
    end
  end

  @impl true
  def rule,
    do:
      "a mint spends the class jig's current location (from the class origin) as a Run input " <>
        "and its payload calls mint on it; the class moves on to that jig's output"

  # A Run jig's location is only as good as its whole trail, so any hop through
  # a replaced block is redone (#53), re-mined or not.
  @impl true
  def retrace_moved?, do: true

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

  # An unencrypted RelayX mint carries its image as the mint's own B:// file.
  # Only the media type is read, and nothing from the tx outlives the call.
  defp image_txid(tx, txid) do
    case BFile.parse(tx) do
      {:ok, %{media_type: "image/" <> _}} -> txid
      _ -> nil
    end
  end
end
