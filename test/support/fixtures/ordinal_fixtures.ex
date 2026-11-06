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
  def item(collection_id, name, owner, traits \\ [{"Eyes", "Reptilian"}], content \\ "<svg/>") do
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
            ["1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", map, :OP_FALSE, content, :OP_ENDIF] ++
            lock(pkh)
      }
    }
  end

  @doc """
  A Run payload output: `OP_FALSE OP_RETURN "run" <5> <app> <json>`.
  `payload` gets defaults for `in`, `ref`, `out`, `del`, `cre`, `exec`.
  """
  def run_payload(payload, app \\ "relayx.io") do
    json =
      %{"in" => 0, "ref" => [], "out" => [], "del" => [], "cre" => [], "exec" => []}
      |> Map.merge(payload)
      |> Jason.encode!()

    %BSV.TxOut{
      satoshis: 0,
      script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "run", <<5>>, app, json]}
    }
  end

  @doc "An OP_RETURN data output (stands in for RelayX's encrypted image)."
  def data_output(data \\ "UNIV"),
    do: %BSV.TxOut{satoshis: 0, script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, data]}}

  @doc "A Run CALL exec entry on input jig `i`."
  def run_call(i, method, args \\ []),
    do: %{"op" => "CALL", "data" => [%{"$jig" => i}, method, args]}

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

  @doc """
  A tx's hex, for one that spends a single input with no script. `BSV.Tx`
  can't be trusted here: `BSV.VarInt.encode/1` (bsv 2.1.0) writes 253 as one
  byte, where the protocol wants `fd fd 00`, so a script of exactly 253 bytes
  serializes to a tx nothing can read. An AIP-signed record lands on that
  length about one time in a thousand, depending on its addresses.
  """
  def raw_tx_hex(%BSV.Tx{inputs: [%BSV.TxIn{outpoint: outpoint}], outputs: outputs}) do
    bytes =
      for %BSV.TxOut{satoshis: satoshis, script: script} <- outputs, into: <<>> do
        script = BSV.Script.to_binary(script)
        <<satoshis::little-64, varint(byte_size(script))::binary, script::binary>>
      end

    input = <<outpoint.hash::binary, outpoint.vout::little-32, 0, 0xFFFFFFFF::little-32>>

    <<1::little-32, 1, input::binary, varint(length(outputs))::binary, bytes::binary, 0::32>>
    |> Base.encode16(case: :lower)
  end

  defp varint(n) when n < 253, do: <<n>>
  defp varint(n) when n <= 0xFFFF, do: <<0xFD, n::little-16>>
  defp varint(n), do: <<0xFE, n::little-32>>

  @doc "A random txid-shaped outpoint for funding inputs."
  def funding_outpoint, do: "#{:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)}_0"

  defp lock(pkh), do: [:OP_DUP, :OP_HASH160, pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]

  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
