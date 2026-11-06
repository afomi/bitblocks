defmodule Bitblocks.WocStub do
  @moduledoc """
  Test WhatsOnChain client (config/test.exs). Answers from the calling test
  process's dictionary, so async tests don't share state:

    * `:woc_txs` — txid => getrawtransaction-style map (see
      `Bitblocks.OrdinalFixtures.publish/2`);
    * `:woc_spent` — "txid_vout" => `{spending_txid, vin}`; absent means unspent;
    * `:woc_block_txids` — block hash => txid list (or `{:error, reason}`);
      absent means WoC doesn't know the block (`{:error, :not_found}`);
    * `:woc_txs_error` — when set, `txs/1` returns `{:error, value}`;
    * `:woc_address_history` — `{address, token}` => `%{history:, next_token:}`
      (or `{:error, reason}`); absent means no history.
  """

  def block_txids(hash) do
    case Process.get(:woc_block_txids, %{})[hash] do
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      txids when is_list(txids) -> {:ok, txids}
    end
  end

  def txs(txids) do
    case Process.get(:woc_txs_error) do
      nil -> known_txs(txids)
      reason -> {:error, reason}
    end
  end

  defp known_txs(txids) do
    known = Process.get(:woc_txs, %{})
    {:ok, for(txid <- txids, tx = known[txid], do: tx)}
  end

  # The public tip is read by the long-lived SyncProgress server, not a test
  # process, so there is no per-test fixture: WoC is simply unavailable.
  def chain_tip, do: {:error, :not_stubbed}

  def address_history(address, token) do
    case Process.get(:woc_address_history, %{})[{address, token}] do
      nil -> {:ok, %{history: [], next_token: nil}}
      {:error, reason} -> {:error, reason}
      %{} = page -> {:ok, page}
    end
  end

  def spent(txid, vout) do
    case Process.get(:woc_spent, %{})["#{txid}_#{vout}"] do
      nil -> {:ok, :unspent}
      {:error, reason} -> {:error, reason}
      {spender, vin} -> {:ok, %{txid: spender, vin: vin}}
    end
  end
end
