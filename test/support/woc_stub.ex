defmodule Bitblocks.WocStub do
  @moduledoc """
  Test WhatsOnChain client (config/test.exs). Answers from the calling test
  process's dictionary, so async tests don't share state:

    * `:woc_txs` — txid => getrawtransaction-style map (see
      `Bitblocks.OrdinalFixtures.publish/2`);
    * `:woc_spent` — "txid_vout" => `{spending_txid, vin}`; absent means unspent.
  """

  def txs(txids) do
    known = Process.get(:woc_txs, %{})
    {:ok, for(txid <- txids, tx = known[txid], do: tx)}
  end

  def spent(txid, vout) do
    case Process.get(:woc_spent, %{})["#{txid}_#{vout}"] do
      nil -> {:ok, :unspent}
      {:error, reason} -> {:error, reason}
      {spender, vin} -> {:ok, %{txid: spender, vin: vin}}
    end
  end
end
