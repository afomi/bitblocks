defmodule Bitblocks.TxTypes.ExamplesTest do
  use Bitblocks.DataCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.OrdinalCollections
  alias Bitblocks.OrdinalCollections.Item
  alias Bitblocks.Tokens
  alias Bitblocks.TxTypes
  alias Bitblocks.TxTypes.Examples

  defp txid(n), do: n |> Integer.to_string(16) |> String.pad_leading(64, "0") |> String.downcase()

  describe "protocol source" do
    test "lists the latest tagged transactions, newest first, up to the limit" do
      for n <- 1..7 do
        transaction_fixture(%{txid: txid(n), block_height: 800_000 + n, protocols: ["Metanet"]})
      end

      transaction_fixture(%{txid: txid(99), block_height: 900_000, protocols: ["MAP"]})

      result = Examples.for_type(TxTypes.get("metanet"))

      assert result.status == :ok
      assert result.count == nil
      assert Enum.map(result.items, & &1.txid) == Enum.map(7..3//-1, &txid/1)
      assert hd(result.items).block_height == 800_007
      assert result.source =~ "Metanet"
    end
  end

  describe "template source" do
    test "matches the type's template hash in output_template_hashes" do
      [p2pkh] = TxTypes.get("p2pkh").examples.template_hashes
      transaction_fixture(%{txid: txid(1), output_template_hashes: [p2pkh, "other"]})
      transaction_fixture(%{txid: txid(2), output_template_hashes: ["other"]})

      result = Examples.for_type(TxTypes.get("p2pkh"))

      assert result.status == :ok
      assert Enum.map(result.items, & &1.txid) == [txid(1)]
    end

    test "matches a shape stamped under either name of an aliased opcode" do
      [one, other] = TxTypes.get("anyone-can-spend").examples.template_hashes
      transaction_fixture(%{txid: txid(1), block_height: 101, output_template_hashes: [one]})
      transaction_fixture(%{txid: txid(2), block_height: 102, output_template_hashes: [other]})

      result = Examples.for_type(TxTypes.get("anyone-can-spend"))

      assert Enum.map(result.items, & &1.txid) == [txid(2), txid(1)]
    end
  end

  describe "tokens source" do
    test "lists a standard's operations and counts its deploys" do
      {:ok, _} =
        Tokens.index_token(%{
          txid: txid(1),
          vout: 0,
          block_height: 100,
          token: %{
            standard: "bsv-21",
            op: "deploy+mint",
            token_id: nil,
            tick: nil,
            amt: "1000",
            max: "1000",
            lim: nil,
            dec: "0",
            sym: "MEME",
            icon: nil
          }
        })

      result = Examples.for_type(TxTypes.get("bsv-21"))

      assert result.status == :ok
      assert result.count == 1
      assert result.count_label == "tokens deployed"
      assert [%{txid: txid, note: note}] = result.items
      assert txid == txid(1)
      assert note =~ "deploy+mint"
      assert note =~ "MEME"

      assert %{status: :ok, count: 0, items: []} = Examples.for_type(TxTypes.get("bsv-20"))
    end
  end

  describe "collections source" do
    test "lists the latest mints of the named collections and counts their items" do
      cid = OrdinalCollections.known()["grand-tardinians"]

      for n <- 1..2 do
        Repo.insert!(%Item{
          collection_id: cid,
          origin: "#{txid(n)}_0",
          mint_txid: txid(n),
          mint_height: 840_000 + n,
          name: "Tardinian #{n}"
        })
      end

      result = Examples.for_type(TxTypes.get("1sat-inscription"))

      assert result.status == :ok
      assert result.count == 2
      assert [%{txid: first, note: "Tardinian 2"}, %{txid: second}] = result.items
      assert {first, second} == {txid(2), txid(1)}
    end
  end

  test "a type with no cheap source says examples are coming" do
    result = Examples.for_type(TxTypes.get("custom"))

    assert result.status == :coming
    assert result.items == []
    assert result.source =~ "comes next"
  end
end
