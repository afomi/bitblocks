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
end
