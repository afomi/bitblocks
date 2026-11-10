defmodule Bitblocks.Chain.TxIngestTest do
  use Bitblocks.DataCase, async: true

  import Bitblocks.OrdinalFixtures

  alias Bitblocks.Chain.{Block, Transaction, TxIngest}

  # #31: inputs/outputs hold one JSON-encoded vin/vout per element, with script
  # hex and asm. A real P2PKH scriptSig alone is ~214 hex chars, so a
  # varchar(255) element can't hold it. Fixtures elsewhere store `[]`, which
  # is why this went unnoticed.
  test "stores real-size vin/vout JSON" do
    {txid, hex} = tx([funding_outpoint()], [p2pkh(address(), 5_000)])

    tx_json = %{
      "txid" => txid,
      "hex" => hex,
      "vin" => [
        %{
          "txid" => String.duplicate("a", 64),
          "vout" => 0,
          "scriptSig" => %{
            "hex" => String.duplicate("ab", 107),
            "asm" => String.duplicate("x", 220)
          }
        }
      ],
      "vout" => [
        %{
          "n" => 0,
          "value" => 0.00005,
          "scriptPubKey" => %{
            "hex" => String.duplicate("cd", 200),
            "asm" => String.duplicate("y", 300)
          }
        }
      ]
    }

    assert :ok = TxIngest.store(tx_json, %Block{hash: "h", height: 1})
    assert [vin] = Repo.get_by!(Transaction, txid: txid).inputs
    assert byte_size(vin) > 255
  end

  describe "a row stored without its place" do
    # Older ingest wrote block_hash only, or neither; the fill used to count
    # such a row as stored and skip it, so it never got its height.
    defp unplaced(attrs) do
      txid = Bitblocks.ChainFixtures.unique_transaction_txid()

      Repo.insert!(
        struct(%Transaction{txid: txid, raw: "00", version: "1", inputs: [], outputs: []}, attrs)
      )

      txid
    end

    test "the fill places it under the block that holds it, and still skips it" do
      no_height = unplaced(%{block_hash: "hash9"})
      no_hash = unplaced(%{})

      existing = TxIngest.existing_txids([no_height, no_hash], %Block{hash: "hash9", height: 9})

      assert existing == MapSet.new([no_height, no_hash])

      for txid <- [no_height, no_hash] do
        assert %{block_hash: "hash9", block_height: 9} = Repo.get_by!(Transaction, txid: txid)
      end
    end

    test "a row under another stored block keeps its place" do
      Bitblocks.ChainFixtures.block_fixture(%{hash: "other", height: 3})
      other = unplaced(%{block_hash: "other", block_height: 3})

      TxIngest.existing_txids([other], %Block{hash: "hash9", height: 9})

      assert %{block_hash: "other", block_height: 3} = Repo.get_by!(Transaction, txid: other)
    end
  end

  test "a tx is stored only with its block's height" do
    {txid, hex} = tx([funding_outpoint()], [p2pkh(address(), 5_000)])

    assert {:error, {:insert_failed, ^txid}} =
             TxIngest.store(%{"txid" => txid, "hex" => hex}, %Block{hash: "h", height: nil})

    refute Repo.get_by(Transaction, txid: txid)
  end
end
