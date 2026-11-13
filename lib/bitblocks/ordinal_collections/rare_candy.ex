defmodule Bitblocks.OrdinalCollections.RareCandy do
  @moduledoc """
  Rare Candy collections (#77): Planetary Skies, Astro Apes, Oni Society, Fox
  Syndicate.

  Rare Candy (rarecandy.io, 2021–2023) is neither 1Sat nor Run. Its shape,
  read from the chain:

    * **The collection** is a tx whose output 0 is a B:// file, `application/json`,
      filename `dogefile`: `name`, `description`, `creator_address`,
      `sats_out`, `total_supply`, `royalty_percentage` and `mint_outpoint`.
    * **An item** is an output locked by

          OP_HASH160 <hash160(collection txid)> OP_EQUALVERIFY
          OP_DUP OP_HASH160 <owner pkh> OP_EQUALVERIFY OP_CHECKSIG
          OP_RETURN <json>

      where the collection txid is pushed in display order, and the JSON is the
      item's metadata: `title`, `description`, `image` (`b://<txid>`),
      `number`, `series` and `attributes` (`trait_type`, `value`). Spending it
      takes the owner's signature and the collection txid itself, so every
      spend names the collection in its unlocking script.

  **Mint:** one tx spends the collection's `mint_outpoint` and holds every
  item (`total_supply` outputs for the four above). The lock alone is only a
  claim: anyone can lock an output to a collection's hash, so an item is an
  output of the tx that spends the mint outpoint, and nothing else. The
  config's `link` is that outpoint. `mint_outpoint` is written two ways on
  chain: Planetary Skies, Astro Apes and Fox Syndicate as the outpoint's bytes
  (txid reversed, then the vout little-endian), Oni Society's second
  collection tx in display order, so `mint_outpoints/1` returns both readings
  and the chain says which exists. Oni Society's first collection tx
  (`fa9f0588…`) declared the same outpoint, but the mint locks its items to the
  second (`9f4b93e9…`), so only the second is the collection.

  **Landing:** an item spent as input `vin` reveals its collection txid, so the
  k-th input revealing it lands in the k-th output locked to its hash. A sale
  through Rare Candy's market moves the item to output 1, after the seller's
  payment. A spend whose counts don't match is `unknown`; a spend that carries
  the lock to no output ends the item's trail (`ended`), since the lock is what
  makes it an item.
  """

  @behaviour Bitblocks.OrdinalCollections.Protocol

  alias Bitblocks.OrdinalCollections.Protocol
  alias Bitblocks.Ordinals.Inscription

  @impl true
  def mint(tx, _txid, link, %{id: cid}) do
    hash = collection_hash(cid)
    items = for {out, vout} <- Enum.with_index(tx.outputs), item = item(out, vout, hash), do: item

    if items != [] and Protocol.input_index(tx, link) != nil,
      do: {:ok, items, []},
      else: :no
  end

  defp item(out, vout, hash) do
    case lock(out.script) do
      %{hash: ^hash, owner: owner, metadata: metadata} ->
        %{
          vout: vout,
          name: text(metadata["title"]),
          content_type: nil,
          traits: traits(metadata["attributes"]),
          image_txid: image_txid(metadata["image"]),
          owner: owner
        }

      _ ->
        nil
    end
  end

  defp traits(attrs) when is_list(attrs) do
    for %{"trait_type" => name, "value" => value} <- attrs, is_binary(name) do
      %{"name" => name, "value" => to_string(value)}
    end
  end

  defp traits(_), do: []

  defp image_txid("b://" <> txid), do: if(txid =~ ~r/\A[0-9a-f]{64}\z/, do: txid)
  defp image_txid(_), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil

  @doc """
  An output's Rare Candy lock: `%{hash, owner, metadata}`, with `hash` the
  20-byte hash160 of the collection txid and `metadata` the decoded JSON
  (`%{}` when it doesn't decode), or nil for any other script.
  """
  def lock(%BSV.Script{chunks: chunks}) do
    case chunks do
      [
        :OP_HASH160,
        <<hash::binary-20>>,
        :OP_EQUALVERIFY,
        :OP_DUP,
        :OP_HASH160,
        <<pkh::binary-20>>,
        :OP_EQUALVERIFY,
        :OP_CHECKSIG,
        :OP_RETURN | data
      ] ->
        %{
          hash: :binary.copy(hash),
          owner: BSV.Address.to_string(%BSV.Address{pubkey_hash: :binary.copy(pkh)}),
          metadata: metadata(data)
        }

      _ ->
        nil
    end
  end

  def lock(_), do: nil

  # Only what an item keeps is copied out; the JSON is a slice of the mint.
  defp metadata([json | _]) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> Map.take(map, ["title", "image", "attributes", "number", "series"])
      _ -> %{}
    end
  end

  defp metadata(_), do: %{}

  @doc "The lock hash of a collection id (`<collection txid>_<vout>`)."
  def collection_hash(cid) do
    [txid | _] = String.split(cid, "_")
    hash160(Base.decode16!(txid, case: :mixed))
  end

  @doc """
  Both readings of a collection's `mint_outpoint` (see the moduledoc), as
  `"txid_vout"`: the outpoint's bytes first, then display order.
  """
  def mint_outpoints(<<txid_hex::binary-64, vout_hex::binary-8>>) do
    with {:ok, txid} <- Base.decode16(txid_hex, case: :mixed),
         {:ok, <<vout::little-32>>} <- Base.decode16(vout_hex, case: :mixed) do
      [
        "#{txid |> reverse() |> Base.encode16(case: :lower)}_#{vout}",
        "#{String.downcase(txid_hex)}_#{vout}"
      ]
    else
      _ -> []
    end
  end

  def mint_outpoints(_), do: []

  @impl true
  def landing(tx, txid, vin, _value_of) do
    revealed = Enum.map(tx.inputs, &revealed/1)

    case Enum.at(revealed, vin) do
      nil ->
        {:unknown, "input #{vin} of #{txid} doesn't reveal a Rare Candy collection"}

      collection ->
        hash = hash160(collection)
        rank = revealed |> Enum.take(vin) |> Enum.count(&(&1 == collection))
        spent = Enum.count(revealed, &(&1 == collection))

        outs =
          for {out, k} <- Enum.with_index(tx.outputs),
              match?(%{hash: ^hash}, lock(out.script)),
              do: k

        cond do
          outs == [] ->
            {:ended, "spent in #{txid} with no output carrying its Rare Candy lock"}

          length(outs) == spent ->
            {:ok, "#{txid}_#{Enum.at(outs, rank)}"}

          true ->
            {:unknown,
             "#{txid} spends #{spent} items of this collection into #{length(outs)} outputs"}
        end
    end
  end

  # The collection txid an input's unlocking script reveals: its last push,
  # when that is 32 bytes (`<sig> <pubkey> <collection txid>`).
  defp revealed(%BSV.TxIn{script: %BSV.Script{chunks: chunks}}) do
    case List.last(chunks) do
      <<collection::binary-32>> when length(chunks) == 3 -> collection
      _ -> nil
    end
  end

  defp revealed(_), do: nil

  @impl true
  def rule,
    do:
      "a mint spends the collection's declared mint outpoint, and its items are the outputs " <>
        "locked to the hash160 of the collection txid"

  # An item's path is read from the tx's bytes, and a re-mined tx has the same
  # bytes: the item keeps its answer.
  @impl true
  def retrace_moved?, do: false

  @impl true
  def owner(%BSV.TxOut{script: script} = _out) do
    case lock(script) do
      %{owner: owner} -> owner
      nil -> Inscription.lock_owner(script)
    end
  end

  defp hash160(bytes), do: :crypto.hash(:ripemd160, :crypto.hash(:sha256, bytes))

  defp reverse(bin),
    do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :erlang.list_to_binary()
end
