defmodule Bitblocks.OrdinalFixtures do
  @moduledoc """
  Real 1Sat transactions for collection tests: inscription outputs, P2PKH
  locks, and inputs spending chosen outpoints. Built with `BSV.Tx`, so txids
  are genuine and `TxIngest`'s body check applies.
  """

  @doc "A fresh P2PKH address."
  def address do
    BSV.PrivKey.new()
    |> BSV.PubKey.from_privkey()
    |> BSV.Address.from_pubkey()
    |> BSV.Address.to_string()
  end

  @doc "A plain P2PKH output."
  def p2pkh(address, satoshis) do
    {:ok, %BSV.Address{pubkey_hash: pkh}} = BSV.Address.from_string(address)

    %BSV.TxOut{
      satoshis: satoshis,
      script: %BSV.Script{chunks: lock(pkh)}
    }
  end

  @doc "A 1-sat contract output (stands in for Bubblemint's mint contract)."
  def contract(tag \\ "mint-contract"),
    do: %BSV.TxOut{satoshis: 1, script: %BSV.Script{chunks: [:OP_FALSE, tag, :OP_DROP]}}

  @doc "A 1-sat collectionItem inscription owned by `owner`."
  def item(collection_id, name, owner, traits \\ [{"Eyes", "Reptilian"}]) do
    {:ok, %BSV.Address{pubkey_hash: pkh}} = BSV.Address.from_string(owner)
    [txid, _] = String.split(collection_id, "_")

    sub_type_data =
      Jason.encode!(%{
        "collectionId" => collection_id,
        "attributes" =>
          for {trait, value} <- traits do
            %{"name" => trait, "details" => %{"name" => value, "description" => "#{value}!"}}
          end
      })

    map =
      BSV.Script.to_binary(%BSV.Script{
        chunks: ["SET", "name", name, "subType", "collectionItem", "subTypeData", sub_type_data]
      })

    parent = txid |> Base.decode16!(case: :lower) |> reverse()

    %BSV.TxOut{
      satoshis: 1,
      script: %BSV.Script{
        chunks:
          [:OP_FALSE, :OP_IF, "ord", :OP_TRUE, "image/svg+xml", :OP_3, parent] ++
            ["1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", map, :OP_FALSE, "<svg/>", :OP_ENDIF] ++
            lock(pkh)
      }
    }
  end

  @doc "Builds a tx spending `inputs` (\"txid_vout\" strings). Returns `{txid, hex}`."
  def tx(inputs, outputs) do
    ins =
      for outpoint <- inputs do
        [txid, vout] = String.split(outpoint, "_")

        %BSV.TxIn{
          outpoint: %BSV.OutPoint{
            hash: txid |> Base.decode16!(case: :lower) |> reverse(),
            vout: String.to_integer(vout)
          },
          script: %BSV.Script{chunks: [:binary.copy(<<0x30>>, 71)]}
        }
      end

    tx = %BSV.Tx{inputs: ins, outputs: outputs}
    {BSV.Tx.get_txid(tx), BSV.Tx.to_binary(tx, encoding: :hex)}
  end

  @doc "Makes `{txid, hex}` fetchable from the WoC stub at `height`; returns the txid."
  def publish({txid, hex}, height \\ 840_000) do
    tx = %{
      "txid" => txid,
      "hex" => hex,
      "vin" => [],
      "vout" => [],
      "blockhash" => "blockhash-#{height}",
      "blockheight" => height,
      "height" => height
    }

    Process.put(:woc_txs, Map.put(Process.get(:woc_txs, %{}), txid, tx))
    txid
  end

  @doc "Records in the WoC stub that `outpoint` is spent by input `vin` of `spender`."
  def spend(outpoint, spender, vin),
    do: Process.put(:woc_spent, Map.put(Process.get(:woc_spent, %{}), outpoint, {spender, vin}))

  @doc "A random txid-shaped outpoint for funding inputs."
  def funding_outpoint, do: "#{:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)}_0"

  defp lock(pkh), do: [:OP_DUP, :OP_HASH160, pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]

  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
