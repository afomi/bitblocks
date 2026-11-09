defmodule Bitblocks.Support.Recent do
  @moduledoc """
  Gifts to the donation address in blocks the sync hasn't reached yet (#74),
  so a sponsor sees a gift soon after it confirms rather than when the sync
  climbs to its block.

  The transactions come from `Bitblocks.Woc.AddressHistory` (bounded and
  cached there, shared with address history); each is counted the same way
  as the stored ones (`Bitblocks.Support.Received`: change is not a gift).
  """

  alias Bitblocks.Support.Received
  alias Bitblocks.Woc.AddressHistory

  @type gift :: %{txid: String.t(), height: non_neg_integer(), sats: pos_integer()}
  @type result ::
          {:ok, %{gifts: [gift()], through_height: non_neg_integer() | nil}}
          | {:error, term()}

  @doc """
  The gifts to `address` in blocks above `height`, each with its txid,
  height and sats, and the WhatsOnChain tip they reach (nil when WoC
  didn't say).
  """
  @spec get(String.t(), integer()) :: result()
  def get(address, height) do
    with {:ok, %{txs: txs, through_height: through}} <- AddressHistory.above(address, height) do
      gifts =
        for %{txid: txid, height: h, tx: tx} <- txs,
            sats = Received.sats(address, tx["vin"] || [], tx["vout"] || []),
            sats > 0,
            do: %{txid: txid, height: h, sats: sats}

      {:ok, %{gifts: gifts, through_height: through}}
    end
  end

  @doc "Forgets every cached result."
  defdelegate clear, to: AddressHistory
end
