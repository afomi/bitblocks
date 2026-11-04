defmodule Bitblocks.FirstSpendFixtures do
  @moduledoc """
  The chain's real first spend, for tests that need true raw txs: block 9's
  coinbase, and block 170's coinbase and the tx that spends block 9's coinbase
  (Satoshi to Hal Finney, 10 coins out, 40 back). The raw hex in
  `test/support/data/first_spend_txs.json` hashes to each txid.
  """

  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.Repo

  @coinbase_9 "0437cd7f8525ceed2324359c2d0ba26006d92d856a9c20fa0241106ee5a597c9"
  @coinbase_170 "b1fea52486ce0c62bb442b530a3f0132b826c74e473d1f2c220bfa78111c5082"
  @first_spend "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"

  def coinbase_9, do: @coinbase_9
  def coinbase_170, do: @coinbase_170
  def first_spend, do: @first_spend

  @doc "Inserts blocks 9 and 170 and their three txs, plus the one spend_index row."
  def insert_first_spend do
    raw = "test/support/data/first_spend_txs.json" |> File.read!() |> Jason.decode!()

    block(9, 1_231_473_279, [@coinbase_9])
    block(170, 1_231_731_025, [@coinbase_170, @first_spend])

    tx(@coinbase_9, 9, raw, true)
    tx(@coinbase_170, 170, raw, true)
    tx(@first_spend, 170, raw, false)

    Repo.insert_all("spend_index", [
      %{
        txid: @coinbase_9,
        vout: 0,
        spending_txid: @first_spend,
        spending_vin: 0,
        inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }
    ])

    :ok
  end

  defp block(height, time, txids) do
    %Block{}
    |> Block.changeset(%{
      hash: height |> Integer.to_string() |> String.pad_leading(64, "b"),
      height: height,
      time: time,
      num_tx: length(txids),
      tx: txids,
      size: 215,
      version: 1,
      merkleroot: String.duplicate("0", 64),
      bits: "1d00ffff",
      nonce: 1,
      difficulty: "1.0",
      sync_state: "completed"
    })
    |> Repo.insert!()
  end

  defp tx(txid, height, raw, coinbase?) do
    %Transaction{}
    |> Transaction.changeset(%{
      txid: txid,
      raw: Map.fetch!(raw, txid),
      version: "1",
      block_hash: height |> Integer.to_string() |> String.pad_leading(64, "b"),
      block_height: height,
      coinbase: coinbase?,
      inputs: [],
      outputs: []
    })
    |> Repo.insert!()
  end
end
